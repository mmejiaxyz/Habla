#!/bin/zsh
# Fetches what Habla for iPhone needs to narrate on the phone itself (Packages/ParadeeKit):
#   - ONNX Runtime 1.32.0 (MIT), Microsoft's official NuGet package → Vendor/ORTiOS.xcframework (static,
#     iPhone + simulator) and Vendor/ORTmac.xcframework (the macOS dylib, only for `swift test` on a Mac)
#   - Paradee 1.3 int8 model + config (Apache-2.0, Hugging Face, pinned revision)
#   - Paradee's own G2P model and word lists (Apache-2.0, GitHub, pinned commit)
#   - misaki's English dictionaries (Apache-2.0, PyPI misaki 0.9.4), gzipped
# Every download is checked against a pinned hash. Re-running only redoes what is missing.
# The outputs are gitignored; Scripts/build.sh and CI run this first.
set -euo pipefail
ROOT="${0:A:h:h}"
PKG="$ROOT/Packages/ParadeeKit"
VENDOR="$PKG/Vendor"
RES="$PKG/Sources/ParadeeKit/Resources"
DL="$ROOT/.build/downloads"
mkdir -p "$VENDOR" "$RES" "$DL"

# download <url> <file> <algorithm 256|512> <hash (hex for 256, base64 for 512)>
fetch() {
  local url=$1 out=$2 algo=$3 want=$4 got
  if [[ -f "$out" ]]; then got=$(digest "$out" "$algo"); [[ "$got" == "$want" ]] && return 0; fi
  echo "• Downloading ${out:t}…"
  curl -fsSL --retry 3 -o "$out.part" "$url"
  got=$(digest "$out.part" "$algo")
  [[ "$got" == "$want" ]] || { echo "Checksum mismatch for ${out:t}: got $got"; rm -f "$out.part"; exit 1; }
  mv "$out.part" "$out"
}
digest() {
  if [[ $2 == 512 ]]; then openssl dgst -sha512 -binary "$1" | base64; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# ONNX Runtime (NuGet's SHA-512, as listed in the package's nuget.org catalog entry).
ORT_VERSION=1.32.0
ORT_NUPKG="$DL/onnxruntime.$ORT_VERSION.nupkg"
fetch "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/$ORT_VERSION/microsoft.ml.onnxruntime.$ORT_VERSION.nupkg" \
  "$ORT_NUPKG" 512 "fj2P9s5o2s5MvwwdDiCF4frwXUJed1gLh1wb0igCUnonbrvfoHMmAFtaj9atgYbBflcQtE3FQ6zGv/s75FQEsQ=="
STAMP="$VENDOR/.onnxruntime-$ORT_VERSION"
if [[ ! -f "$STAMP" || ! -d "$VENDOR/ORTiOS.xcframework" || ! -d "$VENDOR/ORTmac.xcframework" ]]; then
  echo "• Preparing ONNX Runtime $ORT_VERSION…"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  unzip -q -o "$ORT_NUPKG" runtimes/ios/native/onnxruntime.xcframework.zip runtimes/osx-arm64/native/libonnxruntime.dylib LICENSE.txt ThirdPartyNotices.txt -d "$tmp" 2>/dev/null \
    || unzip -q -o "$ORT_NUPKG" runtimes/ios/native/onnxruntime.xcframework.zip runtimes/osx-arm64/native/libonnxruntime.dylib -d "$tmp"
  unzip -q -o "$tmp/runtimes/ios/native/onnxruntime.xcframework.zip" -d "$tmp/ios"
  X="$tmp/ios/onnxruntime.xcframework"
  mkdir -p "$tmp/hdr" "$tmp/dev" "$tmp/sim" "$tmp/mac"
  for h in onnxruntime_c_api.h onnxruntime_ep_c_api.h onnxruntime_error_code.h; do
    cp "$X/ios-arm64/onnxruntime.framework/Headers/$h" "$tmp/hdr/"
  done
  cat > "$tmp/hdr/module.modulemap" <<'EOF'
module COnnxRuntime {
  header "onnxruntime_c_api.h"
  link "c++"
  export *
}
EOF
  cp "$X/ios-arm64/onnxruntime.framework/onnxruntime" "$tmp/dev/libonnxruntime.a"
  cp "$X/ios-arm64_x86_64-simulator/onnxruntime.framework/onnxruntime" "$tmp/sim/libonnxruntime.a"
  cp "$tmp/runtimes/osx-arm64/native/libonnxruntime.dylib" "$tmp/mac/libonnxruntime.1.dylib"
  rm -rf "$VENDOR/ORTiOS.xcframework" "$VENDOR/ORTmac.xcframework"
  xcodebuild -create-xcframework -library "$tmp/dev/libonnxruntime.a" -headers "$tmp/hdr" \
    -library "$tmp/sim/libonnxruntime.a" -headers "$tmp/hdr" -output "$VENDOR/ORTiOS.xcframework" >/dev/null
  xcodebuild -create-xcframework -library "$tmp/mac/libonnxruntime.1.dylib" -headers "$tmp/hdr" \
    -output "$VENDOR/ORTmac.xcframework" >/dev/null
  [[ -f "$tmp/LICENSE.txt" ]] && cp "$tmp/LICENSE.txt" "$VENDOR/onnxruntime-LICENSE.txt"
  rm -f "$VENDOR"/.onnxruntime-*(N)
  touch "$STAMP"
fi

# Paradee 1.3 (int8) at the revision Habla for Mac uses.
HF="https://huggingface.co/sahilmahendrakar/Paradee-8M-v1.3/resolve/b569f5efb789af5ba643a44af348427242ceb784"
fetch "$HF/onnx/paradee_int8.onnx" "$RES/paradee_int8.onnx" 256 f68ed87562d040693dd0dd34e99c11b35ca24294e2149b840503bd1f25a2199f
fetch "$HF/config.json" "$RES/paradee_config.json" 256 021428dbdf35d2cc1d25f66e012ca2fef0439326eb3d60bea79955e223fdd713

# Paradee's G2P (Hindi, French, Spanish, and English words misaki doesn't know), same commit as the Mac.
GH="https://raw.githubusercontent.com/sahilmahendrakar/paradee/2de547e45da92840a636c499eb0782e988be1e47"
fetch "$GH/paradee/data/g2p.onnx" "$RES/g2p.onnx" 256 121609f7860de960e329b882695b46b208232af0b05f8a00918dbd91bc3c5be8
fetch "$GH/paradee/data/g2p.json.gz" "$RES/g2p.json.gz" 256 021865a4b25641c47f110eec78d8f2bcab30dd8e5ebe6ca363e96624327234a5
[[ -f "$VENDOR/paradee-LICENSE.txt" ]] || curl -fsSL --retry 3 -o "$VENDOR/paradee-LICENSE.txt" "$GH/LICENSE"

# misaki's English dictionaries (American and British), gzipped (12 MB → about 3 MB).
MISAKI="$DL/misaki-0.9.4-py3-none-any.whl"
fetch "https://files.pythonhosted.org/packages/82/ec/0ee4110ddb54278b8f21c40a140370ae8f687036c4edf578316602697c56/misaki-0.9.4-py3-none-any.whl" \
  "$MISAKI" 256 90e2eeb169786c014c429e5058d2ea6bcd02d651f2a24450ba6c9ffc0f8da15a
for f in us_gold us_silver gb_gold gb_silver; do
  if [[ ! -f "$RES/$f.json.gz" ]]; then
    unzip -p "$MISAKI" "misaki/data/$f.json" | gzip -9n > "$RES/$f.json.gz.part"
    mv "$RES/$f.json.gz.part" "$RES/$f.json.gz"
  fi
done
echo "Paradee for iPhone is ready ($(du -sh "$RES" | awk '{print $1}') of voice data)."
