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

## Auf der Gegenseite muss rsync liegen

Das ist die Bedingung, an der reines SFTP scheitert. rsync braucht auf der
anderen Seite einen Shell-Zugang und ein rsync, das es dort startet
(`rsync --server`). Ein Zugang, der nur SFTP erlaubt, gibt kein `exec` her.

Betroffen ist ein großer Teil des Shared Hostings. Für solche Ziele gibt es
heute in SyncTool keinen Weg; geplant ist rclone als zweite Übertragungsmaschine.
