#!/usr/bin/env python
"""RVCMac quality metrics (SPEC_030 6.2): compare two sets of offline harness outputs.

How to run, from the repository root:
  export PYIN_CACHE=<dir>   # optional: F0 (pyin) cache, speeds up repeated runs
  venv/bin/python -I scripts/quality_gate.py --root . --a cpu --b ane-gpu \\
      --adir reports/<set>/seed-1/cpu --bdir reports/<set>/seed-1/ane-gpu --out <dir> [--jobs 6]

Dependencies: the project venv (`venv/`, see converter/requirements.txt): numpy, scipy, librosa, soundfile.
Keep `-I`: it stops the script directory from shadowing standard modules.

Input:
  <root>/TestAudio/<name>.wav                    source files, mono 48 kHz
  <adir>/<name>/output.wav, <bdir>/<name>/output.wav   rvcmac-harness output for each source file
  --a and --b are labels. Compare modes (cpu vs ane-gpu), or a candidate against a baseline.

Output:
  <out>/results.json   per-file metrics, the decision below and `passed`
  stdout               PASS or FAIL, then one line per decision metric

Thresholds for regression checks are in docs/BENCHMARKS.md ("Пороги качества"). They use this script's
per-file values. The rule below is the older mode comparison rule and is not those thresholds.

PRE-REGISTERED COMPARISON RULE (fixed before looking at results, applied uniformly):
  d_i = A - B per file (A = tested mode, positive = A worse).
  margin = max(0.25 * SD_between_files(B), FLOOR[metric]); SD with ddof=1.
  One-sided metric PASS: mean(d) + t(0.95, n-1)*SE(d) <= margin AND no file with d_i > 3*margin.
  Two-sided metric (gain_db) PASS: |mean(d)| + t*SE <= margin AND no file with |d_i| > 3*margin.
  Verdict = PASS iff every decision metric passes. Mel pair distance has no direction: info only.
Definitions are in the functions below and are printed by the report.
"""
import argparse, json, os, sys, warnings, hashlib
from concurrent.futures import ProcessPoolExecutor
import numpy as np, soundfile as sf, librosa
from scipy.signal import correlate, resample_poly
from scipy.stats import t as student_t
from numpy.lib.stride_tricks import sliding_window_view as swv
warnings.filterwarnings('ignore')

SR=48000; BLOCK=4800; EPS=1e-12
KS=(8,12,20); K=12; AMP_FLOOR=1e-3; REFRACT=240; BOUND_W=8; JUMP_K=10
ENV_HOP=48; ENV_SMOOTH=240; LAG_RANGE=(-100,800)
FRAME=960; HOP=480; ACTIVE_DB=-60.0; GAP_OUT_DB=-70.0; GAP_IN_DB=-50.0; GAP_MIN=3
F0_HOP16=160; F0_FRAME=1024; FMIN=librosa.note_to_hz('C2'); FMAX=librosa.note_to_hz('C6'); PYIN_RES=0.1
MEL=dict(sr=SR,n_fft=2048,hop_length=HOP,n_mels=80,power=2.0)

def db(p): return 10*np.log10(np.maximum(p,EPS))

def load(p):
    x,sr=sf.read(p,dtype='float64',always_2d=False)
    if x.ndim>1: x=x.mean(1)
    assert sr==SR,(p,sr); return x

def local_sigma(e):
    """Robust local background of e: median over 20 ms (960 samples), step 120, / 0.6745."""
    if len(e)<960: return np.full(len(e),np.median(e)/0.6745+EPS)
    w=swv(e,960)[::120]; m=np.median(w,axis=1)
    c=480+120*np.arange(len(m)); return np.interp(np.arange(len(e)),c,m)/0.6745+EPS

def clicks(x):
    """e[n]=|x[n]-2x[n-1]+x[n-2]|; event if e>K*sigma_local and e>AMP_FLOOR; merged within 5 ms. Returns events by K."""
    e=np.zeros_like(x); e[2:]=np.abs(x[2:]-2*x[1:-1]+x[:-2])
    s=local_sigma(e); r=e/s; res={}
    for k in KS:
        idx=np.where((r>k)&(e>AMP_FLOOR))[0]; ev=[]
        if len(idx):
            cur=[idx[0]]
            for i in idx[1:]:
                if i-cur[-1]<=REFRACT: cur.append(i)
                else: ev.append(cur); cur=[i]
            ev.append(cur)
        res[k]=[(int(c[int(np.argmax(r[c]))]),float(r[c].max()),float(e[c].max())) for c in ev]
    return res

def boundary(x,offset=0):
    """Jump ratio at positions offset+k*4800: |x[b]-x[b-1]| / median(|diff|, b+-240 excl. +-4), amp floor 1e-3."""
    d=np.abs(np.diff(x,prepend=x[0])); pos=np.arange(BLOCK+offset,len(x)-300,BLOCK); r=[]
    for b in pos:
        win=np.r_[d[b-240:b-4],d[b+5:b+241]]; med=np.median(win)+EPS
        r.append(d[b]/med if d[b]>=AMP_FLOOR else 0.0)
    return pos,np.array(r)

def env(x):
    a=np.convolve(np.abs(x),np.ones(ENV_SMOOTH)/ENV_SMOOTH,'same')[::ENV_HOP]; return a
def best_lag(a,b,lo,hi):
    """Lag (env hops) maximizing normalized xcorr of b relative to a (b delayed by lag)."""
    n=min(len(a),len(b)); a=a[:n]-a[:n].mean(); b=b[:n]-b[:n].mean()
    c=correlate(b,a,'full',method='fft'); L=np.arange(-n+1,n); m=(L>=lo)&(L<=hi)
    c=c[m]; L=L[m]; i=int(np.argmax(c)); return int(L[i]),float(c[i]/(np.sqrt((a*a).sum()*(b*b).sum())+EPS))

def windowed_lag(ein,eout,lag):
    """Local lag in 3 s windows (step 1 s), search +-50 ms around global; keeps windows with r>=0.3."""
    w=int(3*SR/ENV_HOP); st=int(SR/ENV_HOP); lags=[]; ts=[]
    n=min(len(ein),len(eout)-lag)
    for s in range(0,max(1,n-w),st):
        a=ein[s:s+w]
        if a.std()<1e-5: continue
        l,c=best_lag(a,eout[s:s+w+lag+50*2][:],lag-50,lag+50)
        if c>=0.3: lags.append(l); ts.append(s*ENV_HOP/SR)
    return np.array(lags),np.array(ts)

def frames_rms(x):
    x=np.pad(x,FRAME//2); w=swv(x,FRAME)[::HOP]; return np.sqrt((w*w).mean(1))

CACHE=os.environ.get('PYIN_CACHE')
def pyin(x,lo,hi):
    if CACHE:
        k=hashlib.sha1(x.tobytes()+repr((lo,hi)).encode()).hexdigest(); p=f'{CACHE}/{k}.npz'
        if os.path.exists(p):
            z=np.load(p); return z['f'],z['v']
        f,v=_pyin(x,lo,hi); np.savez(p+'.tmp.npz',f=f,v=v); os.replace(p+'.tmp.npz',p); return f,v
    return _pyin(x,lo,hi)
def _pyin(x,lo,hi):
    y=resample_poly(x,1,3)
    f,v,_=librosa.pyin(y,fmin=lo,fmax=hi,sr=16000,frame_length=F0_FRAME,hop_length=F0_HOP16,resolution=PYIN_RES,center=True)
    return f,v.astype(bool)

def f0_common_lag(fi,vi,fouts):
    """Per-file F0 alignment, same for both modes: lag in 0..200 ms (10 ms step) minimising the mean over modes of median|e|."""
    best=None
    for lag in range(0,21):
        v=[]
        for fo,vo in fouts:
            n=min(len(fi),len(fo)-lag); k=vi[:n]&vo[lag:lag+n]
            v.append(np.median(np.abs(1200*np.log2(fo[lag:lag+n][k]/(2*fi[:n][k])))) if k.sum()>=20 else 1e9)
        c=float(np.mean(v))
        if best is None or c<best[0]: best=(c,lag)
    return best[1]

def melspec(x):
    S=librosa.feature.melspectrogram(y=x.astype(np.float32),center=True,**MEL)
    return 10*np.log10(np.maximum(S,1e-10))

def one(arg):
    root,a,b,name,cache,adir,bdir=arg
    inp=load(f'{root}/TestAudio/{name}.wav'); ein=env(inp)
    c_path=f'{cache}/{name}.npz'
    res={'name':name,'in_len':len(inp),'modes':{}}
    # control
    ci=clicks(inp); pos_in,rb_in=boundary(inp)
    res['input']={'clicks':len(ci[K]),'clicks_K':{str(k):len(v) for k,v in ci.items()},'bound_clicks':int(sum(any(abs(e[0]-p)<=BOUND_W for p in pos_in) for e in ci[K])),'bound_jumps':int((rb_in>=JUMP_K).sum()),'rms_db':float(db((inp**2).mean())),'dur_s':len(inp)/SR}
    f_in,v_in=pyin(inp,FMIN,FMAX); rms_in=frames_rms(inp); active=db(rms_in**2)>=ACTIVE_DB
    res['input']['active_frac']=float(active.mean()); res['input']['active_db']=float(db((rms_in[active]**2).mean()))
    nb=len(inp)*16000//SR//1600-1; expected=nb*BLOCK
    al={}; mels={}; outs={}
    S_in=melspec(inp)
    raw={m:load(f'{root}/{d}/{name}/output.wav') for m,d in ((a,adir),(b,bdir))}
    pf={m:pyin(raw[m],2*FMIN,2*FMAX) for m in (a,b)}
    f0_lag=f0_common_lag(f_in,v_in,[pf[a],pf[b]]); res['f0_lag_ms']=f0_lag*10
    for m in (a,b):
        x=raw[m]; outs[m]=x
        ex=env(x); lag,conf=best_lag(ein,ex,LAG_RANGE[0],LAG_RANGE[1]); lag_s=max(0,lag*ENV_HOP)
        lags,ts=windowed_lag(ein,ex,lag)
        c=clicks(x); pos,rb=boundary(x); posm,rbm=boundary(x,offset=BLOCK//2)
        al_x=x[lag_s:]; n=min(len(al_x),len(inp)); al[m]=al_x
        r=frames_rms(al_x); N=min(len(r),len(active)); act=active[:N]; r=r[:N]; rdb=db(r[act]**2)
        ga=(db(r**2)<GAP_OUT_DB)&(db(rms_in[:N]**2)>GAP_IN_DB)
        gaps=[]; i=0
        while i<N:
            if ga[i]:
                j=i
                while j<N and ga[j]: j+=1
                if j-i>=GAP_MIN: gaps.append((i*HOP/SR,(j-i)*HOP/SR*1000))
                i=j
            else: i+=1
        f_o,v_o=pf[m][0][f0_lag:],pf[m][1][f0_lag:]
        M=min(len(f_in),len(f_o)); fi,vi,fo,vo=f_in[:M],v_in[:M],f_o[:M],v_o[:M]
        both=vi&vo&np.isfinite(fi)&np.isfinite(fo)
        err=np.full(M,np.nan); err[both]=1200*np.log2(fo[both]/(2*fi[both]))
        d=np.diff(err); de=d[np.isfinite(d)]
        w=np.full(M,np.nan); w[both]=err[both]-1200*np.round(err[both]/1200)   # octave-folded error, cents
        dw=np.diff(w); dw=dw[np.isfinite(dw)]; dw=dw-1200*np.round(dw/1200)
        co=np.full(M,np.nan); co[both]=1200*np.log2(fo[both]); dco=np.diff(co); dco=dco[np.isfinite(dco)]
        A=act[:min(M,N)]; miss=float(((vi[:len(A)]!=vo[:len(A)])&A).sum()/max(1,A.sum()))
        # worst F0 windows (1 s, step 100 ms)
        wins=[]
        for s in range(0,M-100,10):
            e=err[s:s+100]; g=np.isfinite(e)
            if g.sum()>=20: wins.append((s*0.01,float(np.abs(e[g]).mean()),int(g.sum())))
        wins.sort(key=lambda z:-z[1])
        fr=np.where(both)[0]; worstf=sorted(((int(i),float(err[i])) for i in fr),key=lambda z:-abs(z[1]))[:5]
        mels[m]=melspec(al_x)
        L=min(mels[m].shape[1],S_in.shape[1],len(active)); act2=active[:L]
        res['modes'][m]={'out_len':len(x),'expected_len':expected,'len_err':len(x)-expected,'lag_ms':lag_s/48,'lag_conf':conf,
          'lag_win_n':len(lags),'lag_span_ms':float((lags.max()-lags.min())) if len(lags) else None,'lag_std_ms':float(lags.std()) if len(lags) else None,
          'gaps':gaps,'f0_lag_ms':f0_lag*10,
          'clicks':len(c[K]),'clicks_K':{str(k):len(v) for k,v in c.items()},
          'bound_clicks':int(sum(any(abs(e[0]-p)<=BOUND_W for p in pos) for e in c[K])),
          'bound_jumps':int((rb>=JUMP_K).sum()),'mid_jumps':int((rbm>=JUMP_K).sum()),'bound_jump_max':float(rb.max() if len(rb) else 0),
          'top_clicks':sorted([{'t':e[0]/SR,'ratio':e[1],'amp':e[2],'at_boundary':any(abs(e[0]-p)<=BOUND_W for p in pos)} for e in c[K]],key=lambda z:-z['ratio'])[:8],
          'rms_active_db':float(db((r[act]**2).mean())) if act.any() else None,'rms_active_frames':int(act.sum()),'gain_db':float(db((r[act]**2).mean())-db((rms_in[:N][act]**2).mean())) if act.any() else None,
          'f0_frames':int(both.sum()),'f0_mae':float(np.abs(err[both]).mean()) if both.any() else None,'f0_median_abs':float(np.median(np.abs(err[both]))) if both.any() else None,'f0_gt50':float((np.abs(err[both])>50).mean()) if both.any() else None,'f0_octave':float((np.abs(err[both])>600).mean()) if both.any() else None,
          'f0_wrap_mae':float(np.abs(w[both]).mean()) if both.any() else None,'f0_wrap_gt50':float((np.abs(w[both])>50).mean()) if both.any() else None,'f0_wrap_median':float(np.median(np.abs(w[both]))) if both.any() else None,'f0_bias':float(np.median(w[both])) if both.any() else None,'jitter_wrap':float(dw.std()) if len(dw) else None,'jitter_wrap_robust':float(1.4826*np.median(np.abs(dw))) if len(dw) else None,'jitter_err':float(de.std()) if len(de) else None,'jitter_err_robust':float(1.4826*np.median(np.abs(de))) if len(de) else None,'jitter_out':float(dco.std()) if len(dco) else None,
          'voiced_mismatch':miss,'voiced_in_frac':float(vi.mean()),'voiced_out_frac':float(vo.mean()),
          'worst_f0_win':wins[:3],'worst_f0_frames':[(i*0.01,e) for i,e in worstf],
          'mel_to_input_active':float(np.abs(mels[m][:,:L]-S_in[:,:L])[:,act2].mean()),'mel_to_input_all':float(np.abs(mels[m][:,:L]-S_in[:,:L]).mean())}
    # pair mel + pair lag
    L=min(mels[a].shape[1],mels[b].shape[1],len(active)); act=active[:L]; D=np.abs(mels[a][:,:L]-mels[b][:,:L])
    res['pair']={'mel_active':float(D[:,act].mean()),'mel_all':float(D.mean()),'worst_mel_s':float(np.where(act)[0][int(np.argmax(D[:,act].mean(0)))]*0.01) if act.any() else None,
      'lag_a_minus_b_ms':(res['modes'][a]['lag_ms']-res['modes'][b]['lag_ms'])}
    ea,eb=env(outs[a]),env(outs[b]); res['pair']['env_lag_a_vs_b_ms'],res['pair']['env_lag_conf']=best_lag(eb,ea,-100,100)
    return res

# metric: (key getter, floor, two_sided)
DECISION=[('clicks',lambda m:m['clicks'],1.0,False),('bound_clicks',lambda m:m['bound_clicks'],1.0,False),('bound_jumps',lambda m:m['bound_jumps'],1.0,False),
 ('len_err_abs',lambda m:abs(m['len_err']),1.0,False),('gaps',lambda m:len(m['gaps']),1.0,False),('lag_span_ms',lambda m:m['lag_span_ms'] or 0.0,2.0,False),
 ('gain_db',lambda m:m['gain_db'],0.5,True),
 ('f0_mae',lambda m:m['f0_mae'],5.0,False),('f0_gt50',lambda m:m['f0_gt50'],0.005,False),('jitter_err',lambda m:m['jitter_err'],5.0,False),('voiced_mismatch',lambda m:m['voiced_mismatch'],0.01,False)]

def decide(results,a,b):
    n=len(results); tq=float(student_t.ppf(.95,n-1)); out=[]; allpass=True
    for key,g,fl,two in DECISION:
        A=np.array([g(r['modes'][a]) for r in results],float); B=np.array([g(r['modes'][b]) for r in results],float); d=A-B
        margin=max(.25*B.std(ddof=1),fl); se=d.std(ddof=1)/np.sqrt(n); ub=d.mean()+tq*se
        if two: stat=abs(d.mean())+tq*se; ok=stat<=margin and np.abs(d).max()<=3*margin; viol=[(r['name'],float(x)) for r,x in zip(results,d) if abs(x)>3*margin]
        else: stat=ub; ok=stat<=margin and d.max()<=3*margin; viol=[(r['name'],float(x)) for r,x in zip(results,d) if x>3*margin]
        allpass&=ok; out.append(dict(metric=key,mean_A=float(A.mean()),mean_B=float(B.mean()),mean_d=float(d.mean()),sd_d=float(d.std(ddof=1)),stat=float(stat),margin=float(margin),sd_B=float(B.std(ddof=1)),max_d=float(d.max()),min_d=float(d.min()),ok=bool(ok),single_file_violations=viol,two_sided=two,per_file_d=[float(x) for x in d]))
    return out,allpass

def main():
    p=argparse.ArgumentParser(); p.add_argument('--root',required=True); p.add_argument('--a',default='cpu'); p.add_argument('--b',default='ane-gpu'); p.add_argument('--out',required=True); p.add_argument('--jobs',type=int,default=4); p.add_argument('--adir',required=True); p.add_argument('--bdir',required=True); o=p.parse_args()
    os.makedirs(o.out,exist_ok=True); names=sorted(f[:-4] for f in os.listdir(f'{o.root}/TestAudio') if f.endswith('.wav'))
    with ProcessPoolExecutor(o.jobs) as ex: res=list(ex.map(one,[(o.root,o.a,o.b,n,o.out,o.adir,o.bdir) for n in names]))
    dec,ok=decide(res,o.a,o.b)
    json.dump(dict(results=res,decision=dec,passed=bool(ok)),open(f'{o.out}/results.json','w'),indent=1)
    print('PASS' if ok else 'FAIL')
    for d in dec: print({k:(round(v,3) if isinstance(v,float) else v) for k,v in d.items() if k!='per_file_d'})
if __name__=='__main__': main()
