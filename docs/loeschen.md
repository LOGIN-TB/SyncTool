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

## Die eine Ausnahme: innerhalb von `.git/`

Der Lauf, der ein Git-Repo als Einheit überträgt, löscht immer, auch wenn
Löschen im Profil aus ist und im Statusfenster nichts angehakt wurde. Das ist
kein Widerspruch zu den drei Zustimmungen, sondern ihre Begründung von der
anderen Seite: geräumt wird nur innerhalb eines `.git/`, dessen Inhalt in diesem
Moment vollständig auf der Gegenseite liegt. Was dort wegfällt, ist
wiederherstellbar. Ein halbes `.git` ist es nicht.

Abgesichert ist das über die Filterdatei des Laufs: sie nimmt genau die
freigegebenen `.git`-Zweige auf, alles andere fällt mit einer letzten Zeile
heraus. Ausgeschlossene Einträge schützt rsync von sich aus vor `--delete`,
solange `--delete-excluded` fehlt, und das gilt für rsync 3.x und openrsync
gleichermaßen.

Dieser Lauf hat eine eigene Notbremse. `--max-delete` aus dem Profil taugt hier
nicht: nach einem `git gc` auf der Senderseite fallen drüben leicht tausende
lose Objekte weg. Die Grenze kommt deshalb aus den Beständen, die das Prüfen
gemessen hat: gezählt wird, was auf der Empfängerseite unter den freigegebenen
Zweigen liegt und auf der Senderseite nicht, plus ein Zuschlag. Weil openrsync an der Grenze nicht abbricht, sondern
still aufhört zu löschen, zählt SyncTool die Löschzeilen danach nach und bricht
selbst ab, statt ein halb übertragenes `.git` liegenzulassen. Siehe
[git.md](git.md).

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
