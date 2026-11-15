#!/usr/bin/env bash
# Compila TC Atmos Player e crea l'app autonoma.
#
# Variabili richieste:
#   MPV_PREFIX   cartella dove è installata libmpv (include/ e lib/)
#   MPV_SRC      sorgenti di mpv (serve TOOLS/dylib_unhell.py)
#   ENGINE_DIR   cartella con liborender.dylib e libharletty_*_bridge.dylib
# Facoltative:
#   APP_VERSION  versione mostrata dall'app (predefinita 0.1.0)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${MPV_PREFIX:?}" "${MPV_SRC:?}" "${ENGINE_DIR:?}"
APP_VERSION="${APP_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

OUT="$ROOT/build/app"
APP="$OUT/TC Atmos Player.app"
FFMPEG="$(brew --prefix ffmpeg)"
SRC="$ROOT/app/Sources"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine"

echo ">> compilazione del modulo C (analisi Atmos)"
clang -c -O2 -arch arm64 -mmacosx-version-min=15.0 -I"$FFMPEG/include" \
    "$SRC/AtmosProbe.c" -o "$OUT/AtmosProbe.o"

echo ">> compilazione Swift"
swiftc -O -target arm64-apple-macos15.0 -module-name TCAtmosPlayer \
    -import-objc-header "$SRC/Bridging-Header.h" \
    -I "$MPV_PREFIX/include" -I "$SRC" \
    "$SRC"/*.swift "$OUT/AtmosProbe.o" \
    -L "$MPV_PREFIX/lib" -lmpv \
    -L "$FFMPEG/lib" -lavformat -lavcodec -lavutil \
    -framework Cocoa -framework OpenGL -framework QuartzCore -framework SceneKit -framework SwiftUI \
    -o "$APP/Contents/MacOS/TCAtmosPlayer"

echo ">> Info.plist e risorse"
sed -e "s/@VERSION@/$APP_VERSION/" -e "s/@BUILD@/$BUILD_NUMBER/" "$ROOT/app/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
if [ -f "$ROOT/app/AppIcon.icns" ]; then cp "$ROOT/app/AppIcon.icns" "$APP/Contents/Resources/"; fi
cp "$ENGINE_DIR"/liborender.dylib "$APP/Contents/Resources/engine/"
cp "$ENGINE_DIR"/libharletty_*_bridge.dylib "$APP/Contents/Resources/engine/"
mkdir -p "$APP/Contents/Resources/licenses"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/licenses/TC-Atmos-Player-LICENSE.txt"
if [ -d "$ENGINE_DIR/licenses" ]; then cp -R "$ENGINE_DIR/licenses/." "$APP/Contents/Resources/licenses/"; fi

echo ">> librerie dentro l'app"
python3 "$ROOT/scripts/bundle_dylibs.py" "$MPV_SRC/TOOLS" "$APP/Contents/MacOS/TCAtmosPlayer" \
    "$APP/Contents/Resources/engine"/*.dylib

echo ">> firma ad-hoc"
codesign --force --sign - "$APP/Contents/Resources/engine"/*.dylib
codesign --force --sign - "$APP/Contents/MacOS/lib"/*.dylib
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo ">> app pronta: $APP"
