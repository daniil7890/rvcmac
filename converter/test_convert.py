"""Unit tests for the FCPE pinning logic in convert.py.

Heavy imports (torch, numpy) are stubbed, so this runs on a bare python3:
  python3 converter/test_convert.py
Also invoked from the Swift suite (FcpePinningTests).
"""
import hashlib
import importlib.util
import os
import sys
import tempfile
import types
import unittest


def _load_convert():
    torch = types.ModuleType("torch")
    torch.set_grad_enabled = lambda *a, **k: None
    nn = types.ModuleType("torch.nn")

    class Module:
        pass

    nn.Module = Module
    torch.nn = nn
    torch.nn.functional = types.ModuleType("torch.nn.functional")
    sys.modules["numpy"] = types.ModuleType("numpy")
    sys.modules["torch"] = torch
    sys.modules["torch.nn"] = nn
    sys.modules["torch.nn.functional"] = torch.nn.functional
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "convert.py")
    spec = importlib.util.spec_from_file_location("convert_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FcpePinningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.convert = _load_convert()

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = tmp.name
        os.makedirs(os.path.join(self.home, "cache"))
        self.cache = os.path.join(self.home, "cache", "fcpe.pt")
        self.okada = os.path.join(self.home, "okada-fcpe.pt")
        saved = (self.convert.RVCMAC_HOME, self.convert.OKADA_FCPE, self.convert.FCPE_SHA256,
                 os.environ.get("RVCMAC_ALLOW_UNVERIFIED_FCPE"))
        self.convert.RVCMAC_HOME = self.home
        self.convert.OKADA_FCPE = self.okada
        os.environ.pop("RVCMAC_ALLOW_UNVERIFIED_FCPE", None)

        def restore():
            (self.convert.RVCMAC_HOME, self.convert.OKADA_FCPE, self.convert.FCPE_SHA256, env) = saved
            if env is None:
                os.environ.pop("RVCMAC_ALLOW_UNVERIFIED_FCPE", None)
            else:
                os.environ["RVCMAC_ALLOW_UNVERIFIED_FCPE"] = env

        self.addCleanup(restore)

    def _write(self, path, content=b"a different checkpoint"):
        with open(path, "wb") as f:
            f.write(content)
        return hashlib.sha256(content).hexdigest()

    def testCacheMismatchQuarantinesInsteadOfDeleting(self):
        sha = self._write(self.cache)
        with self.assertRaises(SystemExit) as ctx:
            self.convert.find_fcpe_weights()
        kept = f"{self.cache}.unverified-{sha[:8]}"
        self.assertFalse(os.path.exists(self.cache))
        self.assertTrue(os.path.exists(kept), "mismatching cache must be kept, not deleted")
        with open(kept, "rb") as f:
            self.assertEqual(f.read(), b"a different checkpoint")
        msg = str(ctx.exception)
        self.assertIn(self.convert.FCPE_SHA256, msg)
        self.assertIn(sha, msg)
        self.assertIn(kept, msg)

    def testCacheMismatchNeverOverwritesEarlierQuarantine(self):
        sha = self._write(self.cache)
        earlier = f"{self.cache}.unverified-{sha[:8]}"
        self._write(earlier, b"an even earlier checkpoint")
        with self.assertRaises(SystemExit):
            self.convert.find_fcpe_weights()
        with open(earlier, "rb") as f:
            self.assertEqual(f.read(), b"an even earlier checkpoint")
        kept = f"{self.cache}.unverified-{sha[:8]}-1"
        self.assertTrue(os.path.exists(kept))
        with open(kept, "rb") as f:
            self.assertEqual(f.read(), b"a different checkpoint")

    def testCacheMatchingPinIsUsed(self):
        sha = self._write(self.cache)
        self.convert.FCPE_SHA256 = sha
        self.assertEqual(self.convert.find_fcpe_weights(), (self.cache, "cache"))

    def testOkadaMismatchStopsAndKeepsFile(self):
        self._write(self.okada)
        with self.assertRaises(SystemExit) as ctx:
            self.convert.find_fcpe_weights()
        self.assertTrue(os.path.exists(self.okada), "OKADA dev file must be left untouched")
        self.assertIn("RVCMAC_ALLOW_UNVERIFIED_FCPE=1", str(ctx.exception))

    def testOkadaMismatchWithExplicitConfirmation(self):
        self._write(self.okada)
        os.environ["RVCMAC_ALLOW_UNVERIFIED_FCPE"] = "1"
        self.assertEqual(self.convert.find_fcpe_weights(), (self.okada, "okada-unverified"))
        self.assertTrue(os.path.exists(self.okada))

    def testOkadaMatchingPinIsUsed(self):
        sha = self._write(self.okada)
        self.convert.FCPE_SHA256 = sha
        self.assertEqual(self.convert.find_fcpe_weights(), (self.okada, "okada"))


if __name__ == "__main__":
    unittest.main(verbosity=2)