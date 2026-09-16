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

## Löschen ist ein eigener Lauf

Erst geht der Inhalt hinüber, dann wird geräumt. Der zweite Lauf trägt
`--existing --ignore-existing`: Er legt nichts an und ersetzt nichts, er
entfernt nur. So lässt sich jeder der beiden Schritte für sich beurteilen, und
eine Entscheidung des Inhaltslaufs wird nicht nachträglich überschrieben.

Die Reihenfolge ist Absicht. Eine umbenannte Datei geht zuerst unter dem neuen
Namen hinüber und fällt danach unter dem alten weg. Zu keinem Zeitpunkt fehlt
sie auf der Gegenseite.

Geräumt wird mit `--delete-after` statt des voreingestellten
`--delete-during`. Bricht der Lauf mittendrin ab, hat die Empfängerseite noch
alle Daten. Vorher zu löschen hieße, im Abbruchfall Löcher zu hinterlassen.

## Was ersetzt oder gelöscht wird, bleibt 30 Tage liegen

Die Empfängerseite legt jede Datei, die ein Lauf ersetzt oder entfernt, unter
`.synctool-versionen/<Datum-Uhrzeit>/` ab, mit demselben Pfad wie vorher. Der
Ordner ist vom Abgleich ausgenommen, und ausgeschlossen heißt bei rsync
zugleich vor `--delete` geschützt: Kein Lauf räumt die Sicherungen der
Gegenseite weg.

Nach 30 Tagen wird geräumt, die Zahl steht im Profil. `0` schaltet die
Sicherungen ab. Das Alter kommt aus dem Ordnernamen, nicht aus dem Dateisystem;
ein Ordner, den diese App nicht geschrieben hat, bleibt liegen.

**Mit openrsync gibt es beim Löschen keine Sicherung.** Diese Fassung hört mit
`-b --backup-dir` in derselben Zeile still auf zu löschen: kein Abbruch, keine
Meldung, Status 0. SyncTool lässt die Sicherung dort weg und löscht wie
zugesagt, denn ein Lauf, der sich anders verhält als angekündigt, ist der
Anfang jedes Auseinanderlaufens. Mit `brew install rsync` gibt es beides
zusammen. Siehe [rsync.md](rsync.md).

## Die Notbremse

`--max-delete` bricht den Lauf ab, statt mehr Dateien zu entfernen als erlaubt.
Es gelten zwei Anschläge, der kleinere zählt: die Zahl aus dem Profil, Vorgabe
100, und die beim Prüfen gemessene Zahl plus 50. Der zweite ist die Zusage, die
das Statusfenster gemacht hat. Wer dort „17 Dateien löschen?" bestätigt, hat
nicht hundert erlaubt.

**openrsync hält an `--max-delete` nicht an.** Es hört still auf zu löschen und
meldet Erfolg. SyncTool zählt die Löschzeilen deshalb nach und bricht selbst
ab, in jedem Lauf und nicht nur im Git-Lauf.

## Ein unvollständiger Bestand löscht nicht

rsync-Status 24 heißt: Während der Auflistung sind Dateien verschwunden. Die
Liste ist dann zu kurz, und ein fehlender Eintrag sieht aus wie ein gelöschter.
Auf einer solchen Grundlage wird nicht gelöscht. Übertragen geht weiter, denn
eine Datei zu viel zu übertragen ist der harmlose Fehler. Das Statusfenster
sagt, warum nichts zum Löschen angeboten wird.

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
