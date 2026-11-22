#!/bin/zsh
# Sets up the Kokoro-82M renderer used by the Mac side of Habla.
# Creates a local Python env and downloads the ONNX model + voices (~340 MB).
set -euo pipefail
cd "${0:A:h}"
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python "kokoro-onnx>=0.4" "soundfile" "numpy"
mkdir -p models
base="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
for f in kokoro-v1.0.onnx voices-v1.0.bin; do
  [[ -s "models/$f" ]] || curl -fL --retry 3 -o "models/$f" "$base/$f"
done
echo "Kokoro ready: $(pwd)/models"
