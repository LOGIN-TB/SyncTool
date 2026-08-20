#!/bin/bash
# Baut SyncTool.app aus den SwiftPM-Produkten. Braucht kein Xcode,
# die Command Line Tools reichen.
#
# Schalter:
#   NATIVE_ONLY=1           nur die eigene Architektur, fuer die Entwicklung
#   CONFIG=debug            statt release
#   SYNCTOOL_KEEP_VERSION=1 die Baunummer nicht hochzaehlen
#   SIGN_IDENTITY="..."     mit Developer ID und Hardened Runtime signieren
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/build/SyncTool.app"

# Untergrenze wie in Package.swift. Steht hier ausgeschrieben, weil die
# Zielangabe zum Uebersetzen gehoert und nicht abgeleitet werden kann.
DEPLOYMENT="14.0"
ARM_TRIPLE="arm64-apple-macosx$DEPLOYMENT"
X86_TRIPLE="x86_64-apple-macosx$DEPLOYMENT"

# Universal Binaries ohne Xcode: zweimal bauen, dann zusammenfuehren. Der frueher
# hier stehende Weg ueber `swift build --arch arm64 --arch x86_64` braucht xcbuild
# aus einem vollen Xcode. Das ist auf einem Rechner mit blossen Command Line
# Tools nicht vorhanden, der Zweig wurde also nie genommen, und jeder so
# gebaute Stand war stillschweigend arm64-only.
MODE="universal"
[ "${NATIVE_ONLY:-0}" = "1" ] && MODE="native"

build_slice() {  # $1 = Triple, $2 = Kratzverzeichnis
    swift build -c "$CONFIG" --package-path "$ROOT" --triple "$1" --scratch-path "$2" >&2
    swift build -c "$CONFIG" --package-path "$ROOT" --triple "$1" --scratch-path "$2" --show-bin-path
}

echo "==> Weg: $MODE ($CONFIG)"
mkdir -p "$ROOT/build"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ "$MODE" = "universal" ]; then
    ARM_BIN="$(build_slice "$ARM_TRIPLE" "$ROOT/.build-arm64")"
    X86_BIN="$(build_slice "$X86_TRIPLE" "$ROOT/.build-x86_64")"
    for binary in SyncTool SyncToolAskpass; do
        lipo -create "$ARM_BIN/$binary" "$X86_BIN/$binary" \
            -output "$APP/Contents/MacOS/$binary"
    done
else
    swift build -c "$CONFIG" --package-path "$ROOT"
    BIN_DIR="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"
    cp "$BIN_DIR/SyncTool" "$APP/Contents/MacOS/SyncTool"
    cp "$BIN_DIR/SyncToolAskpass" "$APP/Contents/MacOS/SyncToolAskpass"
fi

# Hartes Tor statt einer Meldung. Eine still auf arm64 zusammengefallene
# Auslieferung laeuft auf keinem Intel-Mac, und das faellt auf einem
# Apple-Silicon-Rechner niemandem auf.
ARCHS="$(lipo -archs "$APP/Contents/MacOS/SyncTool")"
echo "==> Architekturen: $ARCHS"
if [ "$MODE" = "universal" ]; then
    case "$ARCHS" in
        *arm64*x86_64* | *x86_64*arm64*) ;;
        *) echo "FEHLER: universal angefordert, bekommen: $ARCHS" >&2; exit 1 ;;
    esac
    # Eine abweichende Untergrenze in einer Scheibe hebt die Anforderung fuer
    # Intel-Nutzer, ohne dass es hier auffaellt.
    for arch in arm64 x86_64; do
        minos="$(otool -arch "$arch" -l "$APP/Contents/MacOS/SyncTool" \
            | awk '/LC_BUILD_VERSION/,/sdk/' | awk '/minos/ {print $2; exit}')"
        if [ "$minos" != "$DEPLOYMENT" ]; then
            echo "FEHLER: $arch verlangt macOS $minos, erwartet $DEPLOYMENT" >&2
            exit 1
        fi
    done
    echo "==> Untergrenze: macOS $DEPLOYMENT in beiden Scheiben"
fi

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Fassung und Baunummer in die Plist des Bundles schreiben. Die Quelle ist die
# VERSION-Datei; die Baunummer zaehlt bei jedem Bau hoch und wird
# zurueckgeschrieben, damit an einem Tag mehrere Baustaende unterscheidbar sind.
#
# SYNCTOOL_KEEP_VERSION=1 laesst die Datei in Ruhe. Ohne das macht jeder Bau
# eine verfolgte Datei schmutzig, und eine Pruefung auf einen sauberen Baum,
# wie sie der Release braucht, waere damit nie erfuellbar.
VERSION_FILE="$ROOT/VERSION"
SHORT_VERSION="$(sed -n '1p' "$VERSION_FILE" 2>/dev/null | tr -d '[:space:]')"
SHORT_VERSION="${SHORT_VERSION:-0.0.0}"
if [ "${SYNCTOOL_KEEP_VERSION:-0}" = "1" ]; then
    BUILD="$(sed -n '2p' "$VERSION_FILE" 2>/dev/null | tr -d '[:space:]')"
    BUILD="${BUILD:-0}"
else
    BUILD="$(bash "$ROOT/Scripts/next-build.sh" "$VERSION_FILE")"
    printf '%s\n%s\n' "$SHORT_VERSION" "$BUILD" > "$VERSION_FILE"
fi

PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
echo "==> Version $SHORT_VERSION, Build $BUILD"

# Ohne Symbol laeuft die App genauso, sie sieht nur nach Platzhalter aus.
ICON="$ROOT/Resources/SyncTool.icns"
if [ -f "$ICON" ]; then
    cp "$ICON" "$APP/Contents/Resources/SyncTool.icns"
else
    echo "==> Kein Symbol unter Resources/SyncTool.icns, 'make icon' erzeugt es"
fi

# Von innen nach aussen. Kein --deep: das ist ein Pruefschalter, kein
# Signierschalter, und es wuerde den zweiten Ausfuehrbaren mit den Flags des
# Bundles neu signieren.
#
# Entitlements braucht die App keine, und das ist eine Entscheidung. Die
# Hardened Runtime beschraenkt, was in DIESEN Prozess geladen wird. `Process`
# laedt nichts, es startet einen neuen Prozess mit eigenem Signierzusammenhang.
# Das Starten von /usr/bin/ssh, /usr/bin/zip und einem Homebrew-rsync braucht
# deshalb kein com.apple.security.cs.disable-library-validation. Waere rsync ein
# Plugin, das in unseren Adressraum geladen wird, waere es umgekehrt. Wer das
# Entitlement "zur Sicherheit" hinzufuegt, schwaecht die App ohne Gegenwert.
if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "==> Signatur mit Developer ID"
    for target in "$APP/Contents/MacOS/SyncToolAskpass" "$APP"; do
        codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" "$target"
    done
    codesign --verify --deep --strict --verbose=2 "$APP"
    codesign -dvvv "$APP" 2>&1 | grep -E '^(Identifier|TeamIdentifier|CodeDirectory)' || true
else
    echo "==> Ad-hoc-Signatur (nur fuer die Entwicklung)"
    codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/SyncToolAskpass"
    codesign --force --sign - --timestamp=none "$APP"
fi

echo "==> Fertig: $APP"
