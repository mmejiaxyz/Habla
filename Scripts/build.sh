#!/bin/zsh
# Builds everything into dist/:
#   dist/Habla.ipa         → install on the iPhone with AltServer/AltStore (it re-signs with your Apple ID)
#   dist/Habla Studio.app  → the Mac app (drag to /Applications if you like)
#
# BUILD_NUMBER (default 0 = local build) becomes CFBundleVersion; the apps update themselves
# from GitHub releases with a higher number (see .github/workflows/release.yml).
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD_NUMBER="${BUILD_NUMBER:-0}"
VERSIONS=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER" MARKETING_VERSION="1.$BUILD_NUMBER")
DD="$ROOT/.build/DD-release"
DIST="$ROOT/dist"
mkdir -p "$DIST"
cd "$ROOT/Apps"
command -v xcodegen >/dev/null && xcodegen generate -q

echo "• Building Habla Studio (Mac)…"
xcodebuild -project Habla.xcodeproj -scheme HablaStudio -configuration Release -derivedDataPath "$DD" "${VERSIONS[@]}" build -quiet
rm -rf "$DIST/Habla Studio.app"
cp -R "$DD/Build/Products/Release/Habla Studio.app" "$DIST/"

echo "• Building Habla (iPhone)…"
xcodebuild -project Habla.xcodeproj -scheme Habla -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$DD" "${VERSIONS[@]}" CODE_SIGNING_ALLOWED=NO build -quiet
PAY="$DD/ipa/Payload"
rm -rf "$DD/ipa"; mkdir -p "$PAY"
cp -R "$DD/Build/Products/Release-iphoneos/Habla.app" "$PAY/"
(cd "$DD/ipa" && rm -f "$DIST/Habla.ipa" && zip -qry "$DIST/Habla.ipa" Payload)

echo "• Packing Habla Studio for updates…"
rm -f "$DIST/Habla-Studio.zip"
(cd "$DIST" && ditto -c -k --sequesterRsrc --keepParent "Habla Studio.app" Habla-Studio.zip)

echo "Done (build $BUILD_NUMBER):"
ls -lh "$DIST" | tail -n +2
