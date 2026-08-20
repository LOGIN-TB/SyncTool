# Was ausgeschlossen bleibt

Zurück zur [Übersicht](../README.md).

Nach jedem Prüfen steht unter dem Ergebnis, wie viele Dateien und Ordner jede
Seite hat und wie viele lokale Einträge die Ausschlussliste verdeckt. Die Zahlen
sind dafür da, sie gegen einen FTP-Client zu halten: was dort zusätzlich zu
sehen ist, steht hier als ausgeschlossener Zweig.

## Wie die Zahl entsteht

Über einen zweiten lokalen Lauf ohne `--exclude-from`. Die Differenz beider
Läufe sind die verdeckten Pfade, zusammengefasst zu ihren obersten Zweigen. Aus
sechsstellig vielen einzelnen Pfaden werden so ein paar Dutzend Zeilen, an denen
sich ablesen lässt, welche Regel greift.

Der zweite Lauf ist rein lokal und kostet keine Anmeldung. Ohne Ausschlüsse im
Profil gibt es nichts zu vergleichen, dann läuft er auch nicht.

## Die Vorgaben

```
.DS_Store   node_modules/   .venv/   venv/   __pycache__/   target/
build/   dist/   .next/   .turbo/   .gradle/   DerivedData/
.synctool-partial/   *.swp   *.log
```

`.git/` steht bewusst **nicht** darin: ohne Historie ist der Abgleich zwischen
Rechnern wertlos.

Wer wirklich alles abgleichen will, leert die Liste in den Einstellungen unter
„Abgleich". Die Liste gehört zum Profil, zwei Profile können verschiedene
Ausschlüsse haben.

## Für das Backup gilt sie nicht

Das Backup packt den ganzen Stammordner, einschließlich `node_modules` und
`build`. Das ist Absicht: die Ausschlussliste ist eine Entscheidung über den
Abgleich, nicht über die Sicherung. Siehe [backup.md](backup.md).
