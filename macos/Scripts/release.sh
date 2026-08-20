#!/bin/bash
# Vom sauberen Baum zum ladbaren Artefakt: bauen, signieren, notarisieren,
# stapeln, verpacken, Pruefsumme.
#
# Aufruf:
#   bash Scripts/release.sh 1.4.0          echter Release, braucht Zertifikat
#   bash Scripts/release.sh 1.4.0 --dev    Trockenlauf ohne Zertifikat
#
# Erwartet in der Umgebung oder in Scripts/release.conf:
#   SIGN_IDENTITY     z.B. "Developer ID Application: Name (TEAMID)"
#   NOTARY_PROFILE    Name aus `xcrun notarytool store-credentials`
#
# Der Grundsatz: an jeder fehlenden Voraussetzung wird laut abgebrochen. Ein
# still unsigniert entstandenes Artefakt waere schlimmer als kein Artefakt, weil
# es aussieht wie eines.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
DIST="$ROOT/dist"
APP="$ROOT/build/SyncTool.app"

die() { echo "FEHLER: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }

VERSION="${1:-}"
MODE="release"
[ "${2:-}" = "--dev" ] && MODE="dev"
[ -n "$VERSION" ] || die "Aufruf: release.sh <Fassung> [--dev]"
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || die "Fassung muss die Form 1.4.0 haben, bekommen: $VERSION"

[ -f "$ROOT/Scripts/release.conf" ] && . "$ROOT/Scripts/release.conf"

# --- Tor 1: keine privaten Werte im Baum -------------------------------------

note "Tor 1: private Werte"
MUSTER="$ROOT/Scripts/private-patterns.txt"
if grep -rInE -f <(grep -v '^#' "$MUSTER" | grep -v '^$') \
    --exclude=private-patterns.txt \
    --exclude-dir=.git --exclude-dir=.build --exclude-dir=.build-arm64 \
    --exclude-dir=.build-x86_64 --exclude-dir=build --exclude-dir=dist "$REPO"; then
    die "Private Werte im Baum. Nichts wird veroeffentlicht."
fi
echo "    sauber"

# --- Tor 2: sauberer Arbeitsbaum ---------------------------------------------

note "Tor 2: Arbeitsbaum"
if [ -d "$REPO/.git" ]; then
    # Die Fassung wird gleich geschrieben, VERSION darf also schmutzig sein.
    dirty="$(git -C "$REPO" status --porcelain | grep -v 'macos/VERSION' || true)"
    [ -z "$dirty" ] || {
        echo "$dirty"
        die "Nicht eingecheckte Aenderungen. Erst committen."
    }
    echo "    sauber"
else
    echo "    kein Git-Verzeichnis, uebersprungen"
fi

# --- Tor 3: Zertifikat und Notarisierung ------------------------------------

if [ "$MODE" = "release" ]; then
    note "Tor 3: Signiermaterial"
    [ -n "${SIGN_IDENTITY:-}" ] || die "SIGN_IDENTITY ist nicht gesetzt. Siehe docs/entwicklung.md."
    [ -n "${NOTARY_PROFILE:-}" ] || die "NOTARY_PROFILE ist nicht gesetzt."
    case "$(security find-identity -v -p codesigning)" in
        *"$SIGN_IDENTITY"*) ;;
        *) die "Identitaet '$SIGN_IDENTITY' liegt nicht im Schluesselbund." ;;
    esac
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null 2>&1 \
        || die "notarytool kennt das Profil '$NOTARY_PROFILE' nicht."
    echo "    Identitaet und Notarisierungsprofil vorhanden"
else
    note "Tor 3: uebersprungen, Trockenlauf"
fi

# --- Tests -------------------------------------------------------------------

note "Tests"
make -C "$ROOT" --no-print-directory test

# --- Fassung setzen und bauen ------------------------------------------------

note "Fassung $VERSION"
printf '%s\n%s\n' "$VERSION" "$(sed -n '2p' "$ROOT/VERSION")" > "$ROOT/VERSION"

note "Bauen"
if [ "$MODE" = "release" ]; then
    SIGN_IDENTITY="$SIGN_IDENTITY" bash "$ROOT/Scripts/bundle.sh"
else
    bash "$ROOT/Scripts/bundle.sh"
fi

BUILD="$(sed -n '2p' "$ROOT/VERSION")"

# --- Tor 4: das gebaute Ergebnis --------------------------------------------

note "Tor 4: Ergebnis pruefen"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/SyncTool")"
case "$ARCHS" in
    *arm64*x86_64* | *x86_64*arm64*) echo "    Architekturen: $ARCHS" ;;
    *) die "Kein Universal Binary: $ARCHS" ;;
esac

if [ "$MODE" = "release" ]; then
    codesign --verify --deep --strict --verbose=2 "$APP" \
        || die "Signaturpruefung fehlgeschlagen"
    info="$(codesign -dvvv "$APP" 2>&1)"
    case "$info" in
        *"flags=0x10000(runtime)"*) ;;
        *) die "Hardened Runtime fehlt. Flags: $(echo "$info" | grep -m1 flags)" ;;
    esac
    case "$info" in
        *"TeamIdentifier=not set"*) die "Keine Team-Kennung in der Signatur" ;;
    esac
    echo "    Signatur, Hardened Runtime und Team-Kennung in Ordnung"
fi

# --- Notarisieren und stapeln -----------------------------------------------

mkdir -p "$DIST"
rm -f "$DIST"/*.dmg "$DIST"/*.zip "$DIST/SHA256SUMS" 2> /dev/null || true

if [ "$MODE" = "release" ]; then
    note "Notarisieren"
    ZIP="$DIST/SyncTool-$VERSION-einreichung.zip"
    # ditto und nicht zip: nur ditto erhaelt die Bundle-Struktur samt
    # Symlinks und erweiterten Attributen so, dass die Signatur gueltig bleibt.
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
        || die "Notarisierung fehlgeschlagen. 'xcrun notarytool log <id>' nennt den Grund."
    rm -f "$ZIP"

    # Gestapelt wird die App und nicht das Archiv: an ein zip laesst sich kein
    # Ticket haengen. Die DMG entsteht danach und traegt das Ticket in sich.
    note "Ticket stapeln"
    xcrun stapler staple "$APP" || die "Stapeln fehlgeschlagen"
    xcrun stapler validate -v "$APP" || die "Ticket nicht gueltig"
fi

# --- DMG ---------------------------------------------------------------------

note "DMG bauen"
if [ "$MODE" = "release" ]; then
    NAME="SyncTool-$VERSION.dmg"
else
    NAME="SyncTool-$VERSION-UNSIGNIERT-dev.dmg"
fi
STAGE="$DIST/.stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Programme"
# Keine .DS_Store im Abbild: sonst reist eine Fensterposition von hier mit.
find "$STAGE" -name .DS_Store -delete
hdiutil create -volname "SyncTool $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO -fs HFS+ "$DIST/$NAME" > /dev/null
rm -rf "$STAGE"

if [ "$MODE" = "release" ]; then
    note "DMG signieren und pruefen"
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DIST/$NAME"
    xcrun stapler staple "$DIST/$NAME" || die "DMG stapeln fehlgeschlagen"
    spctl -a -vvv -t open --context context:primary-signature "$DIST/$NAME" \
        || die "Gatekeeper lehnt die DMG ab"

    note "Pruefsumme"
    (cd "$DIST" && shasum -a 256 "$NAME" > SHA256SUMS && cat SHA256SUMS)
else
    note "Trockenlauf: keine Signatur, keine Pruefsummendatei"
fi

note "Fertig"
echo "    $DIST/$NAME"
echo "    Fassung $VERSION, Build $BUILD"
if [ "$MODE" = "release" ]; then
    echo
    echo "    Naechste Schritte:"
    echo "      git add -A && git commit -m \"Fassung $VERSION\""
    echo "      git tag -a v$VERSION -m \"SyncTool $VERSION\" && git push --follow-tags"
    echo "      gh release create v$VERSION --title \"SyncTool $VERSION\" \\"
    echo "        --notes-file <(sed -n '/## $VERSION/,/^## /p' CHANGELOG.md) \\"
    echo "        \"$DIST/$NAME\" \"$DIST/SHA256SUMS\""
fi
