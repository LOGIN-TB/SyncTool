#!/bin/bash
# Bildschirmfotos fuer die Anleitung, reproduzierbar und ohne echte Daten.
#
# Die App laeuft dabei gegen eine Werkstatt: ein eigenes Verzeichnis mit
# ausgedachten Profilen und zwei Demo-Ordnern. Moeglich ist das ueber
# SYNCTOOL_SUPPORT_DIR. Ein umgebogenes HOME wuerde nicht wirken, weil
# NSHomeDirectory() aus der Benutzerdatenbank kommt und nicht aus der Umgebung.
#
# Ein echter Prueflauf braucht keinen Server: seit es lokale Ordner als Ziel
# gibt, entstehen Uploads, Downloads und Loeschungen zwischen zwei Ordnern auf
# dieser Platte.
#
# Voraussetzung: das Programm, das dieses Skript startet, braucht die Freigabe
# "Bildschirmaufnahme" (Systemeinstellungen, Datenschutz & Sicherheit). Ohne sie
# scheitert screencapture, und zwar leise genug, dass es auffallen muss:
# deshalb prueft dieses Skript jede erzeugte Datei.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
SHOTS="$REPO/docs/images"
WORK="${SYNCTOOL_SHOTS_DIR:-$ROOT/.shots}"
APP="$ROOT/build/SyncTool.app"
BINARY="$APP/Contents/MacOS/SyncTool"

die() { echo "FEHLER: $*" >&2; exit 1; }
note() { echo "==> $*"; }

# --- Schutzgitter, bevor irgendetwas startet ---------------------------------

[ -x "$BINARY" ] || die "Kein Bundle unter $APP. Erst 'make app' laufen lassen."

# Die eine Prueffrage, die zaehlt: laeuft die App gegen die Werkstatt oder gegen
# die echten Zugangsdaten? Kennt das Bundle den Schalter nicht, waere Letzteres
# der Fall, und dann wird hier abgebrochen statt Bildschirmfotos mit echten
# Hostnamen zu erzeugen.
# Ohne Pipe: `grep -q` schliesst sie nach dem ersten Treffer, `strings` bekommt
# SIGPIPE, und mit `pipefail` gilt das als Fehlschlag. Der Waechter haette also
# immer angeschlagen, gerade wenn alles stimmt.
case "$(strings -a "$BINARY")" in
    *SYNCTOOL_SUPPORT_DIR*) ;;
    *) die "Dieses Bundle kennt SYNCTOOL_SUPPORT_DIR nicht. Erst 'make app'." ;;
esac

if pgrep -qx SyncTool; then
    note "Achtung: eine SyncTool-Instanz laeuft schon, die Fenstersuche kann sie erwischen."
fi

# --- Werkstatt aufbauen ------------------------------------------------------

note "Werkstatt unter $WORK"
rm -rf "$WORK"
SUPPORT="$WORK/support"
QUELLE="$WORK/Projekte"
ZIEL="$WORK/Ablage/Projekte"
mkdir -p "$SUPPORT" "$QUELLE/entwurf" "$QUELLE/bilder" "$ZIEL" "$WORK/Ablage/Archive"
chmod 700 "$SUPPORT"

# Beidseitig etwas, damit der Prueflauf Zugaenge, Abgaenge und einen Konflikt
# zeigt und nicht nur eine Spalte.
printf 'Projektnotizen\n' > "$QUELLE/notizen.md"
printf 'Aufgabenliste\n' > "$QUELLE/aufgaben.txt"
printf 'Erste Skizze\n' > "$QUELLE/entwurf/skizze.md"
printf 'Zweite Skizze\n' > "$QUELLE/entwurf/layout.md"
printf 'Bilddaten\n' > "$QUELLE/bilder/titel.png"
printf 'wird ausgeschlossen\n' > "$QUELLE/durchlauf.log"
mkdir -p "$QUELLE/node_modules" && printf 'x\n' > "$QUELLE/node_modules/paket.js"

printf 'Alter Stand\n' > "$ZIEL/altes-dokument.txt"
printf 'Aufgabenliste, aeltere Fassung\n' > "$ZIEL/aufgaben.txt"
touch -t 202601010900 "$ZIEL/aufgaben.txt"

cat > "$SUPPORT/profiles.json" <<JSON
[
  {
    "id" : "A1B2C3D4-1111-4222-8333-444455556666",
    "name" : "Sicherung auf die externe Platte",
    "transportRaw" : "localFolder",
    "providerID" : "local-folder",
    "localRoot" : "$QUELLE",
    "remotePath" : "$ZIEL",
    "host" : "", "user" : "", "share" : "", "port" : 23,
    "authMode" : "password",
    "excludes" : [".DS_Store", "node_modules/", "build/", "*.log"],
    "deleteAllowed" : true, "maxDelete" : 100, "useChecksum" : false,
    "rsyncPath" : "", "backupDestination" : "$WORK/Ablage/Archive",
    "unmountAfterRun" : true, "targetMarkerID" : ""
  },
  {
    "id" : "B2C3D4E5-2222-4333-8444-555566667777",
    "name" : "Hetzner Storage Box",
    "transportRaw" : "sshRsync",
    "providerID" : "hetzner-storagebox",
    "localRoot" : "$QUELLE",
    "remotePath" : "dev",
    "host" : "u123456.your-storagebox.de", "user" : "u123456",
    "share" : "", "port" : 23, "authMode" : "password",
    "excludes" : [".DS_Store", "node_modules/", "build/"],
    "deleteAllowed" : false, "maxDelete" : 100, "useChecksum" : false,
    "rsyncPath" : "", "backupDestination" : "",
    "unmountAfterRun" : true, "targetMarkerID" : ""
  },
  {
    "id" : "C3D4E5F6-3333-4444-8555-666677778888",
    "name" : "Neues Ziel",
    "transportRaw" : "", "providerID" : "",
    "localRoot" : "", "remotePath" : "dev",
    "host" : "", "user" : "", "share" : "", "port" : 23,
    "authMode" : "password",
    "excludes" : [".DS_Store"],
    "deleteAllowed" : false, "maxDelete" : 100, "useChecksum" : false,
    "rsyncPath" : "", "backupDestination" : "",
    "unmountAfterRun" : true, "targetMarkerID" : ""
  }
]
JSON

# --- App starten -------------------------------------------------------------

start_app() {  # $@ = Startargumente
    SYNCTOOL_SUPPORT_DIR="$SUPPORT" "$BINARY" "$@" > "$WORK/app.log" 2>&1 &
    APP_PID=$!
    for _ in $(seq 1 20); do
        /usr/bin/perl -e 'select(undef,undef,undef,0.4)'
        kill -0 "$APP_PID" 2>/dev/null || { cat "$WORK/app.log" >&2; die "App beendete sich sofort"; }
        swift "$ROOT/Scripts/window-id.swift" SyncTool > /dev/null 2>&1 && return 0
    done
    die "Kein Fenster erschienen"
}

stop_app() { kill "${APP_PID:-0}" 2>/dev/null || true; wait "${APP_PID:-0}" 2>/dev/null || true; }
trap stop_app EXIT

# Gesucht wird ueber die Hoehe und nicht ueber den Titel: den liest
# CGWindowList nur mit der Freigabe fuer Bildschirmaufnahme, und beide Fenster
# sind gleich breit. "hoch" ist das Einstellungsfenster, "flach" die
# Statusansicht.
shot() {  # $1 = Dateiname, $2 = hoch|flach
    local name="$1" role="$2" id
    case "$role" in
        hoch)  id="$(swift "$ROOT/Scripts/window-id.swift" SyncTool \
                   | sort -t x -k2 -rn | awk 'NR==1 {print $1}')" ;;
        flach) id="$(swift "$ROOT/Scripts/window-id.swift" SyncTool \
                   | sort -t x -k2 -n  | awk 'NR==1 {print $1}')" ;;
        *) die "Unbekannte Rolle $role" ;;
    esac
    [ -n "$id" ] || die "Kein Fenster ($role) fuer $name"
    rm -f "$SHOTS/$name"
    screencapture -o -x -l "$id" "$SHOTS/$name" \
        || die "screencapture scheiterte. Fehlt die Freigabe 'Bildschirmaufnahme'?"
    # screencapture scheitert auch stumm. Eine fehlende oder winzige Datei ist
    # deshalb ein Fehler und keine Randnotiz.
    [ -s "$SHOTS/$name" ] || die "$name ist leer geblieben"
    local size; size="$(stat -f %z "$SHOTS/$name")"
    [ "$size" -gt 10000 ] || die "$name ist nur $size Bytes gross, das kann nicht stimmen"
    printf '    %-34s %6s KB\n' "$name" "$((size / 1024))"
}

mkdir -p "$SHOTS"

# Ein Lauf je Bild. Neu starten ist billiger als Klickwege nachzubauen, und es
# haelt jedes Bild unabhaengig von der Reihenfolge der anderen.
capture() {  # $1 = Dateiname, $2 = Rolle, $@ = Startargumente
    local name="$1" role="$2"; shift 2
    start_app "$@"
    /usr/bin/perl -e 'select(undef,undef,undef,2)'
    shot "$name" "$role"
    stop_app
}

note "Statusfenster"
capture "statusfenster.png" flach --status

note "Anbieterauswahl"
capture "anbieterauswahl.png" hoch --settings "--profile=Neues Ziel" --tab=verbindung

note "Einstellungen, drei Reiter"
capture "einstellungen-verbindung.png" hoch --settings "--profile=Hetzner" --tab=verbindung
capture "einstellungen-abgleich.png"   hoch --settings "--profile=Sicherung" --tab=abgleich
capture "einstellungen-backup.png"     hoch --settings "--profile=Sicherung" --tab=backup

note "Allgemein"
capture "allgemein.png" hoch --general

note "Fertig. Bilder liegen unter $SHOTS"
if command -v pngquant > /dev/null; then
    note "Verkleinern mit pngquant"
    pngquant --quality 70-90 --skip-if-larger --strip --ext .png --force "$SHOTS"/*.png || true
else
    note "pngquant nicht vorhanden, Bilder bleiben unverkleinert ('brew install pngquant')"
fi
du -sh "$SHOTS"
