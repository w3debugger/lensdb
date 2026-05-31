#!/bin/bash
# Builds LensDB.app -- a self-contained, double-clickable macOS app bundle.
set -euo pipefail
cd "$(dirname "$0")"

echo "Building LensDB (release)..."
swift build -c release

BIN="$(swift build -c release --show-bin-path)/LensDB"
APP="LensDB.app"

echo "Packaging ${APP} ..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/LensDB"
cp Info.plist "${APP}/Contents/Info.plist"
cp AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

# Ad-hoc sign so Gatekeeper lets it launch locally.
codesign --force --sign - "${APP}" >/dev/null 2>&1 || true

echo "Built ${APP}"
echo
echo "Launch it with:"
echo "    open ${APP}"
echo "or, to see logs in the terminal:"
echo "    ./${APP}/Contents/MacOS/LensDB"
