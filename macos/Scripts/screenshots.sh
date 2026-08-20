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
# Im Heimatverzeichnis und nicht im Projektordner: die Pfade stehen in den
# Bildschirmfotos, und ".../macos/.shots/Ablage/Projekte" sieht nach Innereien
# aus. "~/SyncTool-Beispiel/Projekte" liest sich wie das, was es ist. Der Ordner
# wird am Ende wieder entfernt.
WORK="${SYNCTOOL_SHOTS_DIR:-$HOME/SyncTool-Beispiel}"
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
ZIEL="$WORK/Sicherung/Projekte"
mkdir -p "$SUPPORT" "$QUELLE/entwurf" "$QUELLE/bilder" "$ZIEL" "$WORK/Sicherung/Archive"
chmod 700 "$SUPPORT"

# Beidseitig etwas, damit der Prueflauf Zugaenge, Abgaenge und einen Konflikt
# zeigt und nicht nur eine Spalte.
#
# Die Dateien sind absichtlich nicht winzig: mit ein paar Byte stehen im
# Bildschirmfoto ueberall "0 KB", und dann sagt die Groessenspalte nichts.
fuellen() {  # $1 = Pfad, $2 = etwa Kilobyte
    mkdir -p "$(dirname "$1")"
    : > "$1"
    for _ in $(seq 1 "$2"); do
        head -c 1024 /dev/urandom | base64 | head -c 1024 >> "$1"
        printf '\n' >> "$1"
    done
}

fuellen "$QUELLE/notizen.md" 12
fuellen "$QUELLE/aufgaben.txt" 4
fuellen "$QUELLE/entwurf/skizze.md" 48
fuellen "$QUELLE/entwurf/layout.md" 96
fuellen "$QUELLE/bilder/titel.png" 320
fuellen "$QUELLE/durchlauf.log" 64
fuellen "$QUELLE/node_modules/paket.js" 180

fuellen "$ZIEL/altes-dokument.txt" 28
fuellen "$ZIEL/aufgaben.txt" 3
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
    "rsyncPath" : "", "backupDestination" : "$WORK/Sicherung/Archive",
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

# Die Werkstatt raeumt sich selbst weg, auch bei einem Abbruch. Sie liegt im
# Heimatverzeichnis, dort soll nichts liegen bleiben.
aufraeumen() { stop_app; rm -rf "$WORK"; }
trap aufraeumen EXIT

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
capture() {  # $1 = Dateiname, $2 = Rolle, $3 = Wartezeit, $@ = Startargumente
    local name="$1" role="$2" wait="$3"; shift 3
    start_app "$@"
    /usr/bin/perl -e "select(undef,undef,undef,$wait)"
    shot "$name" "$role"
    stop_app
}

note "Statusfenster"
capture "statusfenster.png" flach 6 --status --check

note "Anbieterauswahl"
capture "anbieterauswahl.png" hoch 2 --settings "--profile=Neues Ziel" --tab=verbindung

note "Einstellungen, drei Reiter"
capture "einstellungen-verbindung.png" hoch 2 --settings "--profile=Hetzner" --tab=verbindung
capture "einstellungen-abgleich.png"   hoch 2 --settings "--profile=Sicherung" --tab=abgleich
capture "einstellungen-backup.png"     hoch 2 --settings "--profile=Sicherung" --tab=backup

note "Allgemein"
capture "allgemein.png" hoch 2 --general

note "Fertig. Bilder liegen unter $SHOTS"
if command -v pngquant > /dev/null; then
    note "Verkleinern mit pngquant"
    pngquant --quality 70-90 --skip-if-larger --strip --ext .png --force "$SHOTS"/*.png || true
else
    note "pngquant nicht vorhanden, Bilder bleiben unverkleinert ('brew install pngquant')"
fi
du -sh "$SHOTS"
