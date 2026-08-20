# Löschen

Zurück zur [Übersicht](../README.md).

`--delete` ist der einzige Teil der App, der Daten vernichten kann. Deshalb
steht davor mehr als ein Häkchen.

## Drei unabhängige Zustimmungen

1. Im Profil muss Löschen **erlaubt** sein, Einstellungen, Reiter „Abgleich".
2. Im Statusfenster muss es für diesen Lauf **angehakt** sein.
3. Im Bestätigungsdialog muss es **freigegeben** werden, mit der Liste der
   betroffenen Pfade davor.

Fehlt eine davon, läuft der Abgleich ohne `--delete`. Dateien bleiben dann auf
der Gegenseite liegen, und das ist der harmlose Fehler.

## Die Notbremse

`--max-delete` bricht den Lauf ab, statt mehr Dateien zu entfernen als erlaubt.
Die Zahl steht im Profil, Vorgabe 100. Sie ist kein Feinsteuerungswerkzeug,
sondern ein Anschlag: wenn plötzlich Tausende Dateien zum Löschen anstehen, ist
etwas anderes schiefgegangen.

## Die Gegenseite wird geschützt

Was auf der Empfängerseite neu entstanden ist, geht als `P`-Regel über
`--filter=merge` mit in den Lauf und überlebt `--delete`. Ein Hochladen mit
Löschen entfernt damit nur, was lokal gelöscht wurde, und räumt keine frischen
Dateien der Gegenseite weg.

Die Schutzregeln stehen vor den Ausschlüssen in der Kommandozeile, weil bei
rsync die erste passende Regel gewinnt.

## Eine leere Quelle bricht ab

Der gefährlichste Fall braucht keinen Fehler in der App: der Stammordner liegt
auf einem Laufwerk, das gerade nicht verbunden ist. rsync sieht dann eine Seite
ohne Dateien, und `--delete` räumt die andere aus.

Dagegen prüft SyncTool vor jedem Lauf mit Löschen: ist auf der Quellseite
nichts zu finden, obwohl beim letzten Abgleich dort Dateien lagen, wird
abgebrochen. Die Schwelle liegt bei 25 erinnerten Pfaden, bewusst niedrig. Wer
25 Dateien abgleicht, verliert sie genauso wie jemand mit 25.000.

Ohne Löschen läuft derselbe Fall weiter: dann kann nichts verschwinden, also
gibt es nichts zu verhindern.

Bei einem lokalen Ziel kommt eine zweite Prüfung dazu: fehlt der Zielordner,
bricht der Lauf ab, statt ihn anzulegen. Sonst entstünde auf der Startplatte ein
Ordner mit dem Pfad des nicht verbundenen Laufwerks, und der nächste Lauf
verglich gegen einen leeren Ordner.

## Was kein Löschen ist

Ein Abgleich ist kein Backup. Wer eine Datei versehentlich lokal löscht und
hochlädt, hat sie auch auf der Gegenseite verloren. Dagegen hilft nur ein
Archiv, siehe [backup.md](backup.md).
