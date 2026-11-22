#!/bin/zsh
# Installs Habla's voice engine (Paradee) into a folder (used by Habla's Install button on the Mac).
#   install.sh <target-dir>
# Self-contained: needs nothing pre-installed (no Python, Homebrew, Xcode tools or admin rights).
# Downloads its own `uv`, which fetches a private Python 3.12 into the target folder, then Paradee
# (pinned) and its 8.5 MB model. About 250 MB in all. Removing the folder removes everything.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
SRC="${0:A:h}"
DEST="${1:?target dir}"
PARADEE="git+https://github.com/sahilmahendrakar/paradee@2de547e45da92840a636c499eb0782e988be1e47"
# spaCy's English model, which Paradee's English pronunciation uses (installed now, never at run time).
SPACY_EN="https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"
mkdir -p "$DEST/bin"
cp "$SRC/paradee_worker.py" "$DEST/paradee_worker.py"
cd "$DEST"

# Everything stays inside DEST.
export UV_PYTHON_INSTALL_DIR="$DEST/python"
export UV_CACHE_DIR="$DEST/.uv-cache"
export UV_PYTHON_PREFERENCE=only-managed
export UV_NO_CONFIG=1
export HF_HOME="$DEST/hf"

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
echo "STEP Installing the voice engine…"
bin/uv pip install -q --python .venv/bin/python "$PARADEE" numpy "en_core_web_sm @ $SPACY_EN"
echo "STEP Downloading the voices…"
# Loads the model once (downloads it into DEST/hf) and checks every language speaks.
.venv/bin/python -I - <<'PY'
from paradee import Paradee
tts = Paradee(threads=1)
for voice, text in [("af_heart", "Hello."), ("bf_isabella", "Hello."), ("em_alex", "Hola.")]:
    assert len(tts(text, voice=voice)) > 0, voice
PY
rm -rf "$UV_CACHE_DIR"
echo "DONE"
