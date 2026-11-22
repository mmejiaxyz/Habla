#!/bin/zsh
# Installs Habla's Kokoro voice engine into a target folder (used by Habla Studio).
#   install.sh <target-dir>
# Creates <target>/.venv, copies the worker, downloads the model (~340 MB) and voices.
set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
SRC="${0:A:h}"
DEST="${1:?target dir}"
mkdir -p "$DEST/models"
cp "$SRC/kokoro_worker.py" "$DEST/kokoro_worker.py"
cd "$DEST"
echo "STEP Preparing Python…"
if command -v uv >/dev/null 2>&1; then
  uv venv -q --allow-existing --python 3.12 .venv
  echo "STEP Installing Kokoro…"
  uv pip install -q --python .venv/bin/python "kokoro-onnx>=0.4" soundfile numpy
else
  python3 -c "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)" || { echo "Python 3.10 or newer is needed (install uv: https://docs.astral.sh/uv/)"; exit 1; }
  python3 -m venv .venv
  echo "STEP Installing Kokoro…"
  .venv/bin/pip install -q "kokoro-onnx>=0.4" soundfile numpy
fi
base="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
for f in kokoro-v1.0.onnx voices-v1.0.bin; do
  if [[ ! -s "models/$f" ]]; then
    echo "STEP Downloading $f…"
    curl -fsSL --retry 3 -o "models/$f.part" "$base/$f" && mv "models/$f.part" "models/$f"
  fi
done
echo "DONE"
