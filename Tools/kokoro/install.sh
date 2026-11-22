#!/bin/zsh
# Installs Habla's Kokoro voice engine into a target folder (used by Habla Studio's Install button).
#   install.sh <target-dir>
# Self-contained: needs nothing pre-installed (no Python, Homebrew, Xcode tools or admin rights).
# It downloads its own `uv`, which fetches a private Python 3.12 into the target folder, then the
# Kokoro packages and model (~340 MB). Removing the folder removes everything.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
SRC="${0:A:h}"
DEST="${1:?target dir}"
mkdir -p "$DEST/models" "$DEST/bin"
cp "$SRC/kokoro_worker.py" "$DEST/kokoro_worker.py"
cd "$DEST"

# Everything uv touches stays inside DEST.
export UV_PYTHON_INSTALL_DIR="$DEST/python"
export UV_CACHE_DIR="$DEST/.uv-cache"
export UV_PYTHON_PREFERENCE=only-managed
export UV_NO_CONFIG=1

case "$(uname -m)" in
  arm64)  triple=aarch64-apple-darwin ;;
  x86_64) triple=x86_64-apple-darwin ;;
  *) echo "Unsupported Mac ($(uname -m))"; exit 1 ;;
esac

if [[ ! -x bin/uv ]]; then
  echo "STEP Downloading the installer…"
  base="https://github.com/astral-sh/uv/releases/latest/download"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --retry 3 -o "$tmp/uv.tar.gz" "$base/uv-$triple.tar.gz"
  curl -fsSL --retry 3 -o "$tmp/uv.sha256" "$base/uv-$triple.tar.gz.sha256"
  want="$(awk '{print $1}' "$tmp/uv.sha256")"
  got="$(shasum -a 256 "$tmp/uv.tar.gz" | awk '{print $1}')"
  [[ -n "$want" && "$want" == "$got" ]] || { echo "The installer download was damaged. Try again."; exit 1; }
  tar -xzf "$tmp/uv.tar.gz" -C "$tmp"
  mv "$tmp/uv-$triple/uv" bin/uv
  chmod +x bin/uv
  xattr -d com.apple.quarantine bin/uv 2>/dev/null || true
fi

echo "STEP Preparing Python…"
bin/uv venv -q --allow-existing --python 3.12 .venv
echo "STEP Installing Kokoro…"
bin/uv pip install -q --python .venv/bin/python "kokoro-onnx>=0.4" soundfile numpy
.venv/bin/python -c "import kokoro_onnx, soundfile, numpy" || { echo "Kokoro didn't install correctly."; exit 1; }
rm -rf "$UV_CACHE_DIR"

if [[ -z "${HABLA_SKIP_MODELS:-}" ]]; then
  base="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
  for f in kokoro-v1.0.onnx voices-v1.0.bin; do
    if [[ ! -s "models/$f" ]]; then
      echo "STEP Downloading the voice ($f)…"
      curl -fsSL --retry 3 -C - -o "models/$f.part" "$base/$f" && mv "models/$f.part" "models/$f"
    fi
  done
fi
echo "DONE"
