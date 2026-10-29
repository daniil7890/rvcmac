#!/usr/bin/env python3
"""
RVCMac model converter: RVC (.pth / .safetensors) + ContentVec + FCPE -> Core ML (.mlpackage).

All shapes are static (fixed by the latency config) so Core ML can schedule the
embedder and the synthesizer on the Apple Neural Engine.

Usage:
  convert.py import --model voice.pth [--name NAME] [--block-ms 250 --extra-ms 500 --crossfade-ms 100]
  convert.py config --name NAME --block-ms 250 --extra-ms 500 --crossfade-ms 100

Layout of the models directory:
  shared/N{samples}/embedder.mlpackage, fcpe.mlpackage, fcpe.json
  voices/<name>/voice.json, source.<ext>, synth_<key>.mlpackage
"""
import argparse
import json
import os
import re
import shutil
import sys
import time
import warnings

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

warnings.filterwarnings("ignore")
torch.set_grad_enabled(False)

HERE = os.path.dirname(os.path.abspath(__file__))
# the app passes its data folder; a checkout falls back to the repository root
RVCMAC_HOME = os.environ.get("RVCMAC_HOME") or os.path.dirname(HERE)
sys.path.insert(0, HERE)

CONTENTVEC_REPO = "lengyue233/content-vec-best"
FCPE_URLS = [
    "https://github.com/CNChTu/FCPE/raw/819765c8db719c457f53aaee3238879ab98ed0cd/torchfcpe/assets/fcpe_c_v001.pt",
]
OKADA_FCPE = os.path.expanduser("~/projects/okada-voice-changer/server/dist/MMVCServerSIO/pretrain/fcpe.pt")

SR16 = 16000
HOP16 = 160  # 10 ms at 16 kHz = one RVC feature frame


def log(msg):
    print(msg, flush=True)


def step(msg):
    log(f"STEP: {msg}")


# ----------------------------------------------------------------------------
# Latency config
# ----------------------------------------------------------------------------
class LatencyConfig:
    def __init__(self, block_ms, extra_ms, crossfade_ms):
        for name, v in (("block", block_ms), ("extra", extra_ms), ("crossfade", crossfade_ms)):
            if v % 10 != 0 or v <= 0:
                raise SystemExit(f"ERROR: {name}-ms must be a positive multiple of 10 (got {v})")
        self.block_f = block_ms // 10
        self.extra_f = extra_ms // 10
        self.cf_f = crossfade_ms // 10
        self.sola_f = 1
        self.F = self.block_f + self.sola_f + self.extra_f + self.cf_f  # feature frames in the window
        self.skip = self.extra_f
        self.R = self.F - self.skip  # frames actually decoded (block + sola + crossfade)
        self.flow_head = max(self.skip - 24, 0)
        self.dec_head = self.skip - self.flow_head
        self.N = self.F * HOP16  # window length in samples at 16 kHz
        self.key = f"b{block_ms}_e{extra_ms}_c{crossfade_ms}"
        self.block_ms, self.extra_ms, self.crossfade_ms = block_ms, extra_ms, crossfade_ms

    def as_dict(self):
        return dict(key=self.key, block_ms=self.block_ms, extra_ms=self.extra_ms, crossfade_ms=self.crossfade_ms,
                    block_f=self.block_f, extra_f=self.extra_f, crossfade_f=self.cf_f, sola_f=self.sola_f,
                    F=self.F, skip=self.skip, R=self.R, flow_head=self.flow_head, dec_head=self.dec_head, N=self.N)


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
def bake_weight_norm(model: nn.Module):
    """Remove weight_norm (old hooks and new parametrizations) so the traced graph has plain weights."""
    from torch.nn.utils import parametrize
    for m in model.modules():
        if hasattr(m, "parametrizations"):
            for pname in list(m.parametrizations.keys()):
                parametrize.remove_parametrizations(m, pname, leave_parametrized=True)
        for k, hook in list(m._forward_pre_hooks.items()):
            if hook.__class__.__name__ == "WeightNorm":
                torch.nn.utils.remove_weight_norm(m, name=getattr(hook, "name", "weight"))


def disable_inplace(model: nn.Module):
    for m in model.modules():
        if hasattr(m, "inplace"):
            m.inplace = False


class _NoInplaceLeakyRelu:
    """F.leaky_relu(..., inplace=True) traces into an in-place op; force the functional form."""

    def __enter__(self):
        self.orig = F.leaky_relu

        def lrelu(x, negative_slope=0.01, inplace=False):
            return self.orig(x, negative_slope)
        F.leaky_relu = lrelu
        return self

    def __exit__(self, *a):
        F.leaky_relu = self.orig


def ct_convert(traced, inputs, outputs, precision, path, description):
    import coremltools as ct
    mlmodel = ct.convert(
        traced,
        inputs=inputs,
        outputs=outputs,
        convert_to="mlprogram",
        compute_precision=precision,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = description
    mlmodel.author = "RVCMac converter"
    if os.path.exists(path):
        shutil.rmtree(path)
    mlmodel.save(path)
    return mlmodel


def verify(mlmodel, feed, torch_outs, names):
    """Compare Core ML vs PyTorch on the same input (macOS only)."""
    if sys.platform != "darwin":
        log("  (verification skipped: not macOS)")
        return
    try:
        pred = mlmodel.predict(feed)
    except Exception as e:  # noqa
        log(f"  WARNING: Core ML predict failed during verification: {e}")
        return
    for name, ref in zip(names, torch_outs):
        out = np.asarray(pred[name], dtype=np.float32)
        ref = ref.detach().float().cpu().numpy()
        if out.shape != ref.shape:
            log(f"  WARNING: {name} shape mismatch coreml={out.shape} torch={ref.shape}")
            continue
        err = np.abs(out - ref)
        denom = np.abs(ref).max() + 1e-9
        corr = np.corrcoef(out.ravel(), ref.ravel())[0, 1] if out.size > 1 else 1.0
        log(f"  verify {name}: max_abs_err={err.max():.4g} rel={err.max() / denom:.4g} corr={corr:.5f}")


# ----------------------------------------------------------------------------
# ContentVec (HuBERT) embedder
# ----------------------------------------------------------------------------
class ContentVecWrap(nn.Module):
    def __init__(self, hubert, final_proj):
        super().__init__()
        self.hubert = hubert
        self.final_proj = final_proj

    def forward(self, audio):  # [1, N] float32, 16 kHz
        out = self.hubert(audio, output_hidden_states=True, return_dict=False)
        hidden = out[1]
        units12 = hidden[12]  # RVC v2 (768)
        units9 = self.final_proj(hidden[9])  # RVC v1 (256)
        return units9, units12


def load_contentvec():
    from huggingface_hub import hf_hub_download
    from transformers import HubertConfig, HubertModel
    step("Downloading ContentVec weights (first time only, ~380 MB)")
    cfg_path = hf_hub_download(CONTENTVEC_REPO, "config.json")
    bin_path = hf_hub_download(CONTENTVEC_REPO, "pytorch_model.bin")
    cfg = HubertConfig.from_json_file(cfg_path)
    for attr in ("_attn_implementation", "attn_implementation"):
        try:
            setattr(cfg, attr, "eager")
        except Exception:  # noqa
            pass
    hubert = HubertModel(cfg)
    state = torch.load(bin_path, map_location="cpu", weights_only=True)
    proj = nn.Linear(cfg.hidden_size, cfg.classifier_proj_size)
    proj.weight.data.copy_(state.pop("final_proj.weight"))
    proj.bias.data.copy_(state.pop("final_proj.bias"))
    missing, unexpected = hubert.load_state_dict(state, strict=False)
    missing = [k for k in missing if "masked_spec_embed" not in k]
    if missing:
        raise SystemExit(f"ERROR: ContentVec weights missing keys: {missing[:8]}")
    if unexpected:
        log(f"  note: unexpected ContentVec keys ignored: {unexpected[:5]}")
    hubert.eval()
    bake_weight_norm(hubert)
    return ContentVecWrap(hubert, proj).eval(), cfg


def hubert_frames(cfg, n):
    for k, s in zip(cfg.conv_kernel, cfg.conv_stride):
        n = (n - k) // s + 1
    return n


def build_embedder(out_dir, lc: LatencyConfig):
    import coremltools as ct
    path = os.path.join(out_dir, "embedder.mlpackage")
    model, cfg = load_contentvec()
    E = hubert_frames(cfg, lc.N)
    step(f"Converting ContentVec embedder (window {lc.N} samples -> {E} frames)")
    x = (torch.randn(1, lc.N) * 0.1).float()
    with torch.no_grad():
        ref = model(x)
        traced = torch.jit.trace(model, x, check_trace=False)
    ml = ct_convert(
        traced,
        inputs=[ct.TensorType(name="audio", shape=(1, lc.N), dtype=np.float32)],
        outputs=[ct.TensorType(name="units9", dtype=np.float32), ct.TensorType(name="units12", dtype=np.float32)],
        precision=ct.precision.FLOAT16,
        path=path,
        description=f"ContentVec 500 (layers 9+proj, 12), N={lc.N}",
    )
    verify(ml, {"audio": x.numpy()}, ref, ["units9", "units12"])
    return E


# ----------------------------------------------------------------------------
# FCPE pitch extractor (mel front-end built in, so Core ML gets raw audio)
# ----------------------------------------------------------------------------
def _patch_fcpe_attention():
    """Replace einsum-heavy Performer helpers with matmul equivalents (Core ML friendly)."""
    from torchfcpe import model_conformer_naive as mcn

    def softmax_kernel(data, *, projection_matrix, is_query, normalize_data=True, eps=1e-4, device=None):
        data_normalizer = (data.shape[-1] ** -0.25) if normalize_data else 1.0
        ratio = projection_matrix.shape[0] ** -0.5
        data_dash = torch.matmul(data_normalizer * data, projection_matrix.t().type_as(data))
        diag_data = (data ** 2).sum(dim=-1, keepdim=True) / 2.0 * (data_normalizer ** 2)
        if is_query:
            data_dash = ratio * (torch.exp(data_dash - diag_data - data_dash.max(dim=-1, keepdim=True).values) + eps)
        else:
            data_dash = ratio * (torch.exp(data_dash - diag_data + eps))
        return data_dash.type_as(data)

    def linear_attention(q, k, v):
        k_sum = k.sum(dim=-2)  # [b,h,d]
        d_inv = 1.0 / (torch.matmul(q, k_sum.unsqueeze(-1)) + 1e-8)  # [b,h,n,1]
        context = torch.matmul(k.transpose(-1, -2), v)  # [b,h,d,e]
        return torch.matmul(q, context) * d_inv

    mcn.softmax_kernel = softmax_kernel
    mcn.linear_attention = linear_attention


def find_fcpe_weights():
    if os.path.exists(OKADA_FCPE):
        return OKADA_FCPE
    cache = os.path.join(RVCMAC_HOME, "cache", "fcpe.pt")
    if os.path.exists(cache):
        return cache
    import urllib.request
    os.makedirs(os.path.dirname(cache), exist_ok=True)
    step("Downloading FCPE weights")
    for url in FCPE_URLS:
        try:
            urllib.request.urlretrieve(url, cache + ".part")
            os.replace(cache + ".part", cache)
            return cache
        except Exception as e:  # noqa
            log(f"  download failed from {url}: {e}")
    raise SystemExit("ERROR: could not obtain FCPE weights (fcpe.pt)")


class FcpeWrap(nn.Module):
    """audio [1,N] -> latent [1, N//160+1, out_dims]. Mel front-end replicates the fork's FCPE path."""

    def __init__(self, fcpe, n_samples):
        super().__init__()
        import librosa
        from scipy.signal import get_window
        n_fft, hop = 1024, 160
        basis = np.fft.fft(np.eye(n_fft))
        cutoff = n_fft // 2 + 1
        basis = np.vstack([np.real(basis[:cutoff]), np.imag(basis[:cutoff])])
        basis = basis * get_window("hann", n_fft, fftbins=True)
        self.register_buffer("basis", torch.tensor(basis, dtype=torch.float32).unsqueeze(1))  # [1026,1,1024]
        mel = librosa.filters.mel(sr=SR16, n_fft=n_fft, n_mels=128, fmin=0, fmax=8000)
        self.register_buffer("mel", torch.tensor(mel, dtype=torch.float32))  # [128,513]
        self.cutoff = cutoff
        self.hop = hop
        self.n_out = n_samples // hop + 1
        self.fcpe = fcpe

    def forward(self, audio):
        x = audio.unsqueeze(1)
        x = F.pad(x, (432, 432), mode="reflect")  # Wav2Mel padding ((win - hop) // 2)
        x = F.pad(x, (512, 512), mode="reflect")  # STFT centre padding (n_fft // 2)
        spec = F.conv1d(x, self.basis, stride=self.hop)  # [1,1026,T]
        re, im = spec[:, : self.cutoff], spec[:, self.cutoff:]
        mag = torch.sqrt(re * re + im * im + 1e-12)
        mel = torch.matmul(self.mel, mag)  # [1,128,T]
        mel = torch.log(torch.clamp(mel, min=1e-5))
        mel = mel.transpose(1, 2)[:, : self.n_out]
        return self.fcpe(mel)  # sigmoid latent


def build_fcpe(out_dir, lc: LatencyConfig):
    import coremltools as ct
    from torchfcpe.models_infer import spawn_model
    from torchfcpe.tools import DotDict
    _patch_fcpe_attention()
    step("Converting FCPE pitch extractor")
    ckpt = torch.load(find_fcpe_weights(), map_location="cpu", weights_only=False)
    ckpt["config_dict"]["model"]["conv_dropout"] = 0.0
    ckpt["config_dict"]["model"]["atten_dropout"] = 0.0
    args = DotDict(ckpt["config_dict"])
    net = spawn_model(args)
    net.load_state_dict(ckpt["model"])
    net.eval()
    bake_weight_norm(net)
    disable_inplace(net)
    wrap = FcpeWrap(net, lc.N).eval()
    x = (torch.randn(1, lc.N) * 0.1).float()
    with torch.no_grad():
        ref = wrap(x)
        traced = torch.jit.trace(wrap, x, check_trace=False)
    path = os.path.join(out_dir, "fcpe.mlpackage")
    ml = ct_convert(
        traced,
        inputs=[ct.TensorType(name="audio", shape=(1, lc.N), dtype=np.float32)],
        outputs=[ct.TensorType(name="latent", dtype=np.float32)],
        precision=ct.precision.FLOAT32,  # Performer attention overflows in fp16
        path=path,
        description=f"FCPE pitch latent, N={lc.N}",
    )
    verify(ml, {"audio": x.numpy()}, [ref], ["latent"])
    meta = dict(f0_min=float(net.f0_min), f0_max=float(net.f0_max), out_dims=int(net.out_dims),
                frames=int(ref.shape[1]), threshold=0.006)
    with open(os.path.join(out_dir, "fcpe.json"), "w") as f:
        json.dump(meta, f, indent=2)


def ensure_shared(models_dir, lc: LatencyConfig):
    out_dir = os.path.join(models_dir, "shared", f"N{lc.N}")
    os.makedirs(out_dir, exist_ok=True)
    meta_path = os.path.join(out_dir, "shared.json")
    meta = json.load(open(meta_path)) if os.path.exists(meta_path) else {}
    if not os.path.exists(os.path.join(out_dir, "embedder.mlpackage")) or "E" not in meta:
        meta["E"] = build_embedder(out_dir, lc)
    else:
        log(f"  embedder for N={lc.N} already exists")
    if not os.path.exists(os.path.join(out_dir, "fcpe.mlpackage")) or not os.path.exists(os.path.join(out_dir, "fcpe.json")):
        build_fcpe(out_dir, lc)
    else:
        log(f"  fcpe for N={lc.N} already exists")
    meta["N"] = lc.N
    with open(meta_path, "w") as f:
        json.dump(meta, f, indent=2)
    return meta["E"]


# ----------------------------------------------------------------------------
# RVC synthesizer
# ----------------------------------------------------------------------------
# Set by --unsafe-pickle. A .pth file is a pickle: loading it with weights_only=False can run
# arbitrary code from the file, so by default only plain tensors/containers are accepted.
ALLOW_UNSAFE_PICKLE = False


def load_checkpoint(path):
    try:
        return torch.load(path, map_location="cpu", weights_only=True)
    except Exception as e:  # noqa
        if not ALLOW_UNSAFE_PICKLE:
            raise SystemExit(
                f"ERROR: {os.path.basename(path)} contains more than plain weights and was not loaded "
                f"(safe mode, torch weights_only=True: {type(e).__name__}).\n"
                "  Prefer a .safetensors version of the model. If you trust where this file came from, "
                "re-run with --unsafe-pickle."
            )
        log("  WARNING: loading with weights_only=False (--unsafe-pickle): the file can execute code")
        return torch.load(path, map_location="cpu", weights_only=False)


def load_rvc(path):
    """Returns (config list, state_dict, version, f0)."""
    if path.endswith(".safetensors"):
        from safetensors import safe_open
        with safe_open(path, "pt", device="cpu") as f:
            meta = f.metadata() or {}
            state = {k: f.get_tensor(k) for k in f.keys()}
        config = json.loads(meta["config"])
        version = meta.get("version", "v2" if "v2" in os.path.basename(path) else "v1")
        f0 = int(meta.get("f0", 1))
    else:
        cpt = load_checkpoint(path)
        config = cpt["config"]
        state = cpt["weight"]
        version = cpt.get("version", "v1")
        f0 = int(cpt.get("f0", 1))
    # some trainers store version incorrectly: trust the embedding size
    emb_in = state["enc_p.emb_phone.weight"].shape[1]
    version = "v2" if emb_in == 768 else "v1"
    return config, state, version, f0


class SynthWrap(nn.Module):
    def __init__(self, model, lc: LatencyConfig, E, emb_channels, sid):
        super().__init__()
        self.m = model
        self.lc = lc
        self.E = E
        self.C = emb_channels
        g = model.emb_g.weight[sid].view(1, -1, 1).clone()
        self.register_buffer("g", g)
        self.register_buffer("lengths", torch.tensor([lc.F], dtype=torch.long))

    def decode(self, z, sine):
        dec = self.m.dec
        har = torch.tanh(dec.m_source.l_linear(sine)).transpose(1, 2)  # [1,1,L]
        x = dec.conv_pre(z) + dec.cond(self.g)
        for i in range(dec.num_upsamples):
            x = F.leaky_relu(x, dec.lrelu_slope)
            x = dec.ups[i](x)
            x = x + dec.noise_convs[i](har)
            xs = None
            for j in range(dec.num_kernels):
                r = dec.resblocks[i * dec.num_kernels + j](x)
                xs = r if xs is None else xs + r
            x = xs / dec.num_kernels
        x = F.leaky_relu(x, 0.01)
        x = dec.conv_post(x)
        return torch.tanh(x)

    def forward(self, phone, pitch, noise, sine):
        # phone: features already at 10 ms frames [1, F, C] (upscale + index + protect are done in the app)
        lc = self.lc
        m_p, logs_p, x_mask = self.m.enc_p(phone, pitch, self.lengths, lc.flow_head)
        z_p = (m_p + torch.exp(logs_p) * noise * 0.66666) * x_mask
        z = self.m.flow(z_p, x_mask, g=self.g, reverse=True)
        z = z[:, :, lc.dec_head: lc.dec_head + lc.R]
        o = self.decode(z, sine)
        return torch.clamp(o[:, 0, :], -1.0, 1.0)


def build_synth(voice_dir, voice, lc: LatencyConfig, E):
    import coremltools as ct
    from rvc_infer.models import SynthesizerTrnMs256NSFsid, SynthesizerTrnMs768NSFsid
    src = os.path.join(voice_dir, voice["source"])
    config, state, version, f0 = load_rvc(src)
    cls = SynthesizerTrnMs768NSFsid if version == "v2" else SynthesizerTrnMs256NSFsid
    model = cls(*config, is_half=False)
    missing, unexpected = model.load_state_dict(state, strict=False)
    missing = [k for k in missing if not k.startswith("enc_q.")]
    if missing:
        raise SystemExit(f"ERROR: model weights missing keys: {missing[:8]}")
    model.eval()
    if hasattr(model, "enc_q"):
        del model.enc_q
    bake_weight_norm(model)
    disable_inplace(model)
    C = voice["emb_channels"]
    inter = model.inter_channels
    upp = int(model.dec.upp)  # samples per 10 ms frame at the model rate
    if upp * 100 != int(voice["sr"]):
        raise SystemExit(f"ERROR: unexpected upsample factor {upp} for {voice['sr']} Hz")
    wrap = SynthWrap(model, lc, E, C, voice.get("sid", 0)).eval()

    step(f"Converting synthesizer ({version}, {voice['sr']} Hz, F={lc.F}, decode {lc.R} frames)")
    phone = torch.randn(1, lc.F, C) * 0.5
    pitch = torch.randint(20, 200, (1, lc.F), dtype=torch.int32)
    noise = torch.randn(1, inter, lc.F - lc.flow_head)
    sine = (torch.randn(1, lc.R * upp, 1) * 0.1)
    with torch.no_grad(), _NoInplaceLeakyRelu():
        ref = wrap(phone, pitch, noise, sine)
        traced = torch.jit.trace(wrap, (phone, pitch, noise, sine), check_trace=False)
    name = f"synth_{lc.key}.mlpackage"
    path = os.path.join(voice_dir, name)
    ml = ct_convert(
        traced,
        inputs=[
            ct.TensorType(name="phone", shape=(1, lc.F, C), dtype=np.float32),
            ct.TensorType(name="pitch", shape=(1, lc.F), dtype=np.int32),
            ct.TensorType(name="noise", shape=(1, inter, lc.F - lc.flow_head), dtype=np.float32),
            ct.TensorType(name="sine", shape=(1, lc.R * upp, 1), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="audio", dtype=np.float32)],
        precision=ct.precision.FLOAT16,
        path=path,
        description=f"RVC {version} synthesizer {voice['name']} {lc.key}",
    )
    verify(ml, {"phone": phone.numpy(), "pitch": pitch.numpy(), "noise": noise.numpy(), "sine": sine.numpy()},
           [ref], ["audio"])
    voice["inter_channels"] = int(inter)
    voice["upp"] = int(upp)
    return name


# ----------------------------------------------------------------------------
# Feature index (faiss) -> raw float32 matrix for exact search in the app
# ----------------------------------------------------------------------------
def find_index_near(model_path):
    d = os.path.dirname(model_path)
    stem = os.path.splitext(os.path.basename(model_path))[0].lower()
    cands = [f for f in os.listdir(d) if f.lower().endswith(".index") and not f.lower().startswith("trained")]
    if not cands:
        return None
    cands.sort(key=lambda f: (stem not in f.lower(), not f.lower().startswith("added"), f))
    return os.path.join(d, cands[0])


def add_index(voice_dir, voice, index_path):
    import faiss
    step(f"Reading index {os.path.basename(index_path)}")
    idx = faiss.read_index(index_path)
    if idx.ntotal == 0 or not idx.is_trained:
        raise SystemExit("ERROR: empty or untrained index (use added_*.index, not trained_*.index)")
    if idx.d != voice["emb_channels"]:
        raise SystemExit(f"ERROR: index dim {idx.d} does not match model features {voice['emb_channels']}")
    vecs = np.ascontiguousarray(idx.reconstruct_n(0, idx.ntotal), dtype=np.float32)
    vecs.tofile(os.path.join(voice_dir, "index.f32"))
    voice["index"] = dict(file="index.f32", count=int(vecs.shape[0]), dim=int(vecs.shape[1]),
                          source=os.path.basename(index_path))
    log(f"  index: {vecs.shape[0]} vectors x {vecs.shape[1]}")


# ----------------------------------------------------------------------------
# Commands
# ----------------------------------------------------------------------------
def safe_name(s):
    s = re.sub(r"[^\w\-. ]+", "_", s, flags=re.UNICODE).strip()
    return s or "voice"


def write_voice(voice_dir, voice):
    with open(os.path.join(voice_dir, "voice.json"), "w") as f:
        json.dump(voice, f, indent=2, ensure_ascii=False)


def build_config(models_dir, voice_dir, voice, lc):
    E = ensure_shared(models_dir, lc)
    synth = build_synth(voice_dir, voice, lc, E)
    cfg = lc.as_dict()
    cfg.update(E=E, synth=synth, shared=f"shared/N{lc.N}", phone_frames=lc.F)
    voice.setdefault("configs", {})[lc.key] = cfg
    write_voice(voice_dir, voice)
    log(f"DONE: {voice['name']} [{lc.key}]")


def cmd_import(a):
    src = os.path.abspath(os.path.expanduser(a.model))
    if not os.path.exists(src):
        raise SystemExit(f"ERROR: file not found: {src}")
    name = safe_name(a.name or os.path.splitext(os.path.basename(src))[0])
    step(f"Reading model {os.path.basename(src)}")
    config, state, version, f0 = load_rvc(src)
    if not f0:
        raise SystemExit("ERROR: models without pitch (nono / f0=0) are not supported yet")
    sr = config[-1]
    sr = {"32k": 32000, "40k": 40000, "48k": 48000}.get(sr, sr)
    voice_dir = os.path.join(a.models_dir, "voices", name)
    os.makedirs(voice_dir, exist_ok=True)
    ext = os.path.splitext(src)[1]
    shutil.copy2(src, os.path.join(voice_dir, "source" + ext))
    voice = dict(
        name=name, version=version, sr=int(sr), sid=a.sid,
        emb_channels=768 if version == "v2" else 256,
        emb_output="units12" if version == "v2" else "units9",
        source="source" + ext, configs={},
    )
    log(f"  {version}, {sr} Hz, speakers={state['emb_g.weight'].shape[0]}")
    index_path = a.index or find_index_near(src)
    if index_path:
        add_index(voice_dir, voice, os.path.abspath(os.path.expanduser(index_path)))
    else:
        log("  no .index file found next to the model (index can be added later)")
    build_config(a.models_dir, voice_dir, voice, LatencyConfig(a.block_ms, a.extra_ms, a.crossfade_ms))


def cmd_config(a):
    voice_dir = os.path.join(a.models_dir, "voices", a.name)
    vpath = os.path.join(voice_dir, "voice.json")
    if not os.path.exists(vpath):
        raise SystemExit(f"ERROR: voice not found: {a.name}")
    voice = json.load(open(vpath))
    build_config(a.models_dir, voice_dir, voice, LatencyConfig(a.block_ms, a.extra_ms, a.crossfade_ms))


def cmd_index(a):
    voice_dir = os.path.join(a.models_dir, "voices", a.name)
    vpath = os.path.join(voice_dir, "voice.json")
    if not os.path.exists(vpath):
        raise SystemExit(f"ERROR: voice not found: {a.name}")
    voice = json.load(open(vpath))
    add_index(voice_dir, voice, os.path.abspath(os.path.expanduser(a.index)))
    write_voice(voice_dir, voice)
    log(f"DONE: index added to {a.name}")


def main():
    p = argparse.ArgumentParser(description="RVCMac model converter")
    p.add_argument("--models-dir", default=os.path.join(RVCMAC_HOME, "models"))
    sub = p.add_subparsers(dest="cmd", required=True)
    si = sub.add_parser("index")
    si.add_argument("--name", required=True)
    si.add_argument("--index", required=True)
    for name in ("import", "config"):
        s = sub.add_parser(name)
        s.add_argument("--block-ms", type=int, default=250)
        s.add_argument("--extra-ms", type=int, default=500)
        s.add_argument("--crossfade-ms", type=int, default=100)
        if name == "import":
            s.add_argument("--model", required=True)
            s.add_argument("--name")
            s.add_argument("--sid", type=int, default=0)
            s.add_argument("--index", help="faiss .index (default: auto-detect next to the model)")
        s.add_argument("--unsafe-pickle", action="store_true",
                       help="allow .pth files that need full pickle loading (can execute code; only for trusted files)")
        if name != "import":
            s.add_argument("--name", required=True)
    a = p.parse_args()
    global ALLOW_UNSAFE_PICKLE
    ALLOW_UNSAFE_PICKLE = bool(getattr(a, "unsafe_pickle", False))
    a.models_dir = os.path.abspath(os.path.expanduser(a.models_dir))
    t0 = time.time()
    try:
        {"import": cmd_import, "config": cmd_config, "index": cmd_index}[a.cmd](a)
    except SystemExit:
        raise
    except Exception as e:  # noqa
        import traceback
        traceback.print_exc()
        log(f"ERROR: {type(e).__name__}: {e}")
        sys.exit(1)
    log(f"  total {time.time() - t0:.0f}s")


if __name__ == "__main__":
    main()
