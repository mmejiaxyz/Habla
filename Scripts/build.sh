#!/bin/zsh
# Builds everything into dist/:
#   dist/Habla.ipa         → install on the iPhone with AltServer/AltStore (it re-signs with your Apple ID)
#   dist/Habla.app         → the Mac app (move it to /Applications so it can update itself)
#
# BUILD_NUMBER (default 0 = local build) becomes CFBundleVersion; the apps update themselves
# from GitHub releases with a higher number (see .github/workflows/release.yml).
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD_NUMBER="${BUILD_NUMBER:-0}"
# The account Worker's address (never committed): HABLA_BRIDGE_URL, else the one this Mac uses.
if [[ -z "${HABLA_BRIDGE_URL:-}" ]]; then
  BRIDGE_JSON="$HOME/Library/Application Support/Habla Studio/Security/bridge.json"
  [[ -f "$BRIDGE_JSON" ]] && HABLA_BRIDGE_URL=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("url",""))' "$BRIDGE_JSON" 2>/dev/null)
fi
VERSIONS=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER" MARKETING_VERSION="1.$BUILD_NUMBER" HABLA_BRIDGE_URL="${HABLA_BRIDGE_URL:-}")
DD="$ROOT/.build/DD-release"
DIST="$ROOT/dist"
mkdir -p "$DIST"
# The iPhone's on-device voice (ONNX Runtime + Paradee model, hash-pinned downloads).
"$ROOT/Scripts/fetch-paradee.sh"
cd "$ROOT/Apps"
command -v xcodegen >/dev/null && xcodegen generate -q

echo "• Building Habla for Mac…"
xcodebuild -project Habla.xcodeproj -scheme HablaStudio -configuration Release -derivedDataPath "$DD" "${VERSIONS[@]}" build -quiet
rm -rf "$DIST/Habla.app" "$DIST/Habla Studio.app"
cp -R "$DD/Build/Products/Release/Habla.app" "$DIST/"

echo "• Building Habla for iPhone…"
xcodebuild -project Habla.xcodeproj -scheme Habla -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$DD" "${VERSIONS[@]}" CODE_SIGNING_ALLOWED=NO build -quiet
PAY="$DD/ipa/Payload"
rm -rf "$DD/ipa"; mkdir -p "$PAY"
cp -R "$DD/Build/Products/Release-iphoneos/Habla.app" "$PAY/"
(cd "$DD/ipa" && rm -f "$DIST/Habla.ipa" && zip -qry "$DIST/Habla.ipa" Payload)

echo "• Packing the Mac app for updates…"
rm -f "$DIST/Habla-Studio.zip" "$DIST/Habla-Mac.zip"
(cd "$DIST" && ditto -c -k --sequesterRsrc --keepParent "Habla.app" Habla-Mac.zip)

echo "Done (build $BUILD_NUMBER):"
ls -lh "$DIST" | tail -n +2
