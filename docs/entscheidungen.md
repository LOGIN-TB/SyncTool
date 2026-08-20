# Wie der Abgleich entscheidet

Zurück zur [Übersicht](../README.md).

„Prüfen" listet beide Seiten vollständig auf und vergleicht die zwei Bestände.

## Der Trick mit dem leeren Verzeichnis

Die Auflistung ist ein Trockenlauf gegen ein leeres Verzeichnis. Dann fehlt beim
Empfänger jeder Eintrag, und rsync nennt ihn samt Größe, Zeitstempel und, auf
Wunsch, Prüfsumme. Heraus kommt dasselbe Ausgabeformat, das die App ohnehin
liest, einschließlich leerer Ordner und Symlinks.

Der Vorteil gegenüber zwei Differenzläufen: für jeden Pfad steht danach fest, ob
es ihn auf der anderen Seite gibt, statt es aus zwei Meldungen zu erschließen.
Der Fernbestand kostet eine Anmeldung, die lokalen Läufe keine.

`--dry-run` steht in diesem Lauf fest verdrahtet, und `--delete` gibt es dort
gar nicht: ein Bestandslauf darf unter keinen Umständen etwas anfassen.

## Die Regeln

- Datei nur auf einer Seite vorhanden, siehe unten „Gelöscht oder neu".
- Gleiche Prüfsumme, also gleich, egal wie weit die Zeitstempel auseinanderliegen.
- Zeitstempel unterscheiden sich um mehr als eine Sekunde, die neuere Seite gewinnt.
- Gleicher Zeitstempel, andere Größe, also Konflikt.
- Beide Seiten seit dem letzten erfolgreichen Abgleich geändert, also Konflikt,
  auch wenn eine Seite neuer ist.
- Verzeichnisse werden allein an ihrer Existenz gemessen. Größe und Zeit eines
  Ordners sagen über seinen Inhalt nichts. Ein leerer Ordner, den es nur auf
  einer Seite gibt, wird gemeldet; ein Ordner mit Inhalt zieht mit seinen
  Dateien mit.
- Symlinks werden am Ziel des Verweises gemessen, nicht an Größe oder Zeit. Deren
  Zeitstempel lassen sich auf der Gegenseite nicht setzen und wichen sonst
  dauerhaft ab.

Konflikte werden nur angezeigt, nicht aufgelöst. Welche Richtung zuerst
ausgeführt wird, gewinnt.

Prüfsummen kommen nur mit einem rsync 3.x mit. openrsync kennt das Feld nicht,
dort läuft der Vergleich über Größe und Zeitstempel. Siehe [rsync.md](rsync.md).

## Gelöscht oder neu

Eine Datei, die es nur auf einer Seite gibt, ist zweideutig: entweder ist sie
dort neu entstanden, oder sie wurde auf der anderen Seite gelöscht. Die
Bestandslisten allein können das nicht unterscheiden. SyncTool merkt sich
deshalb nach jeder Übertragung den gemeinsamen Dateibestand je Profil unter
`~/Library/Application Support/SyncTool/inventory-<profil>.json`.

- Pfad stand schon im Bestand, also wurde er auf der anderen Seite gelöscht und
  wird als Löschung ausgewiesen, nicht als Übertragung.
- Pfad ist neu, also normale Übertragung in die passende Richtung.

Der Bestand wird aus den beiden Ständen abgeleitet, die die Prüfung vorher
gemessen hat, nicht aus dem lokalen Verzeichnisbaum:

| Lauf | neuer Bestand |
| --- | --- |
| nicht sauber durchgelaufen | Schnittmenge beider Seiten |
| Herunterladen mit Löschen | Bestand der Gegenseite |
| Herunterladen ohne Löschen | Bestand der Gegenseite plus was hier noch aus dem alten Bestand liegt |
| Hochladen mit Löschen | lokaler Bestand |
| Hochladen ohne Löschen | lokaler Bestand plus was dort noch aus dem alten Bestand liegt |

Die beiden Zeilen „ohne Löschen" halten fest, was auf der Gegenseite gelöscht
wurde und hier noch liegt. Fiele es aus dem Bestand, gälte es beim nächsten
Prüfen wieder als Neuzugang von dort.

Reine Mengenarithmetik, damit sie sich ohne Dateisystem prüfen lässt.

## Bestandslisten aus einer älteren Fassung

Frühere Fassungen schrieben den kompletten lokalen Baum in die Bestandsliste,
auch Dateien, die nie auf der Gegenseite waren. Solche Dateien galten beim
Prüfen als „dort gelöscht", wurden nie hochgeladen und verschwanden bei einem
Herunterladen mit Löschen.

Solche Listen werden beim ersten Prüfen an der Fernseite geradegezogen: was
darin steht, aber nicht auf der Gegenseite liegt, war nie gemeinsamer Bestand.
Der Preis ist bekannt und liegt in der harmlosen Richtung: ein Pfad, der
wirklich auf der Gegenseite gelöscht wurde und hier noch liegt, gilt einmalig
als Upload statt als Löschung.

## Wenn noch kein Bestand da ist

Solange für ein Profil noch kein Bestand geschrieben wurde, entscheidet
ersatzweise der Zeitstempel: was älter ist als der letzte Abgleich, war damals
schon da und gilt als gelöscht. Diese Notlösung liegt daneben, wenn Dateien mit
altem Zeitstempel neu angelegt werden, etwa beim Zurückspielen eines Backups.
