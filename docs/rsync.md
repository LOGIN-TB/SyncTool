# Welches rsync

Zurück zur [Übersicht](../README.md).

macOS liefert seit Sequoia openrsync aus, Protokoll 29. Das funktioniert, ist
gegen ein rsync 3.x auf der Gegenstelle aber die anfälligere Kombination.

SyncTool sucht in dieser Reihenfolge und nimmt das erste Ergebnis:

```
/opt/homebrew/bin/rsync
/usr/local/bin/rsync
/usr/bin/rsync
```

Ein rsync 3.x aus Homebrew wird also bevorzugt. Findet die App nur openrsync,
schlägt sie `brew install rsync` vor. Welche Fassung läuft, steht unter
„Programm, Allgemein".

## Was mit openrsync fehlt

**Prüfsummen im Bestandslauf.** openrsync kennt das Ausgabefeld `%C` nicht und
schriebe das Literal in die Zeile. Die App erkennt das und lässt den
Prüfsummenvergleich weg; verglichen wird dann über Größe und Zeitstempel.

**Sicherungen beim Löschen**, siehe unten.

Das Häkchen „Prüfsumme" im Profil bleibt gesetzt, es wirkt nur nicht. Das ist
richtig so: wer später Homebrew-rsync installiert, will seine Einstellung
wiederfinden.

## Warum nicht `-a`

`-a` wäre bequemer, zieht aber `-o` und `-g` mit, also Eigentümer und Gruppe.
Auf einer Hetzner Storage Box scheitert jedes `chown`, und der Lauf endet mit
Fehlerstatus, obwohl die Daten stimmen. Deshalb steht dort `-rlptz`: rekursiv,
Symlinks, Rechte, Zeiten, komprimiert.

Bei einem Lauf im Dateisystem fällt das `z` weg. Komprimieren würde dort nur
die Luft komprimieren und Rechenzeit kosten.

## Prüfsummen und Git-Repos

Ein Ref ist immer gleich lang. Ohne Prüfsummenvergleich entscheiden Größe und
Zeitstempel, und zwei Refs gleicher Länge mit Zeitstempeln innerhalb einer
Sekunde gelten dann als gleich. Für einen Stammordner voller Repos gehört das
Häkchen „Prüfsumme" deshalb an, und dafür braucht es ein rsync 3.x.

## Die Filterregeln des Git-Laufs

Der Lauf, der ein Repo als Einheit überträgt, nimmt über `--filter=merge` nur
die freigegebenen `.git`-Zweige auf und wirft mit einer letzten Zeile alles
andere heraus. Jedes Elternsegment steht als eigene Zeile darin, sonst steigt
rsync gar nicht erst in den Ordner hinab.

Darauf steht die ganze Konstruktion: ein ausgeschlossener Eintrag ist bei rsync
zugleich vor `--delete` geschützt, solange `--delete-excluded` fehlt. Der Lauf
darf deshalb `--delete` tragen und räumt trotzdem nur innerhalb der Zweige auf.
Das gilt für rsync 3.x und für openrsync gleichermaßen; beide Fassungen sind mit
denselben Integrationstests belegt.

Ein Unterschied bleibt: **`--max-delete` bricht bei rsync 3.x ab (Status 25), bei
openrsync nicht.** Dort heißt es nur „once MAX files have been deleted, do not
delete any more files", der Lauf hört still auf zu löschen und hinterlässt genau
den Mischzustand, um den es geht. SyncTool zählt die Löschzeilen deshalb nach
und bricht selbst ab, in jedem Lauf. Siehe [git.md](git.md).

## openrsync kann Sichern und Löschen nicht zusammen

Stehen `-b --backup-dir=…` und `--delete` in derselben Zeile, löscht openrsync
nichts. Kein Abbruch, keine Meldung, Status 0. Der Nutzer hat im
Rücksprachefenster Dateien zum Löschen freigegeben, und der Lauf meldet Erfolg,
ohne sie anzufassen.

Gemessen mit `env -i PATH=/usr/bin:/bin`, also openrsync gegen sich selbst. Mit
einem rsync 3.x im Pfad fällt es nicht auf: openrsync startet dann jenes als
Gegenstelle, und die macht es richtig. Genau deshalb ist es so lange
unbemerkt geblieben.

SyncTool lässt die Sicherung in dieser Kombination weg und löscht wie zugesagt.
Ein Lauf, der sich anders verhält als angekündigt, ist der Anfang jedes
Auseinanderlaufens. Der Integrationstest „openrsync kann Sichern und Löschen
nicht zusammen" hält den Befund fest; fällt der Fehler eines Tages weg, schlägt
er an, und dann darf die Sonderbehandlung raus.

## Die Pfadliste des Inhaltslaufs

Ein Lauf überträgt genau die gemessenen Pfade, über `--files-from` und
`--from0`. Nullterminiert, damit ein Zeilenumbruch im Dateinamen keine Frage
mehr ist, und ohne jedes Maskierzeichen: In dieser Datei steht ein Name und
kein Muster.

Jedem Eintrag steht `./` voran. Ohne das fällt ein Pfad, der mit `#` oder `;`
beginnt, still aus: rsync liest solche Zeilen als Kommentar, und zwar auch mit
`--from0`. Beide Fassungen übertrugen die Datei einfach nicht und meldeten
nichts.

Ein Unterschied zwischen den Fassungen, der hier nicht stört: `--exclude-from`
wirkt bei rsync 3.x nicht auf die in der Liste genannten Pfade, bei openrsync
schon. Die Liste stammt aus dem Bestandslauf, der die Ausschlüsse bereits
angewandt hat, es steht also ohnehin nichts Ausgeschlossenes darin.

## Auf der Gegenseite muss rsync liegen

Das ist die Bedingung, an der reines SFTP scheitert. rsync braucht auf der
anderen Seite einen Shell-Zugang und ein rsync, das es dort startet
(`rsync --server`). Ein Zugang, der nur SFTP erlaubt, gibt kein `exec` her.

Betroffen ist ein großer Teil des Shared Hostings. Für solche Ziele gibt es
heute in SyncTool keinen Weg; geplant ist rclone als zweite Übertragungsmaschine.
