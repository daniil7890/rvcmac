#!/usr/bin/env bash
# Creates the Python environment for the RVCMac model converter and converts the first voice.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$ROOT/setup.log"
exec > >(tee "$LOG") 2>&1
echo "=== setup $(date) ==="
cd "$ROOT"

PY="${PY:-python3.12}"
command -v "$PY" >/dev/null || { echo "ERROR: $PY not found (brew install python@3.12)"; exit 1; }

if [[ ! -x venv/bin/python ]]; then
  "$PY" -m venv venv
fi
source venv/bin/activate
python -m pip install --upgrade pip wheel
pip install -r converter/requirements.txt
python - <<'PYEOF'
import torch, coremltools, transformers, torchfcpe
print("torch", torch.__version__, "| coremltools", coremltools.__version__, "| transformers", transformers.__version__)
PYEOF

MODEL="${1:-}"
if [[ -n "$MODEL" ]]; then
  echo "=== converting $MODEL ==="
  python converter/convert.py import --model "$MODEL"
fi
echo "=== setup finished ==="
