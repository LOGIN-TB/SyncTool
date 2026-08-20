#!/bin/bash
# Bildet die naechste Baunummer aus der zweiten Zeile der VERSION-Datei.
#
# Format: JJJJ.MM.TT-N. Wird an einem Tag mehrmals gebaut, zaehlt N hoch;
# ein neuer Tag faengt wieder bei 1 an. Alles, was nicht dem Format
# entspricht, gilt als "noch nichts da" und ergibt heute mit -1.
set -euo pipefail

FILE="${1:-}"
TODAY="${SYNCTOOL_TODAY:-$(date +%Y.%m.%d)}"

previous=""
if [ -n "$FILE" ] && [ -f "$FILE" ]; then
    previous="$(sed -n '2p' "$FILE" | tr -d '[:space:]')"
fi

if [[ "$previous" =~ ^([0-9]{4}\.[0-9]{2}\.[0-9]{2})-([0-9]+)$ ]] \
    && [ "${BASH_REMATCH[1]}" = "$TODAY" ]; then
    printf '%s-%d\n' "$TODAY" "$(( BASH_REMATCH[2] + 1 ))"
else
    printf '%s-1\n' "$TODAY"
fi
