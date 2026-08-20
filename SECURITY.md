# Sicherheitslücken melden

Bitte nicht über ein öffentliches Issue. Zwei Wege:

- **GitHub**, bevorzugt: auf der Seite „Security" dieses Repos unter „Report a
  vulnerability". Das ist ein privater Kanal, nur für die Betreuer sichtbar.
- **E-Mail** an die Adresse im Profil des Repo-Inhabers, falls GitHub nicht in
  Frage kommt.

Eine Antwort kommt in der Regel innerhalb einer Woche. Das ist keine Zusage
über 24 Stunden, sondern eine ehrliche Einschätzung für ein Projekt mit einem
Betreuer.

## Was besonders interessiert

Diese vier Bereiche tragen die Sicherheitsaussagen der App. Ein Fehler darin
wiegt schwerer als eine unschöne Meldung:

- **Passwortweg.** Das Passwort steht im Schlüsselbund und geht über einen
  Unix-Domain-Socket in einem Verzeichnis mit Modus 0700 an den Askpass-Helfer.
  Es soll nie in der Kommandozeile, nie in einer Datei und nie in einer
  Umgebungsvariablen landen. Siehe [docs/passwort.md](docs/passwort.md).
- **Host-Key-Prüfung.** SyncTool führt ein eigenes `known_hosts` und arbeitet
  mit `StrictHostKeyChecking=yes`. Der Helfer antwortet auf
  Host-Key-Rückfragen ausdrücklich nicht.
- **Löschsicherheit.** `--delete` braucht drei unabhängige Zustimmungen, dazu
  `--max-delete` und Schutzregeln für neue Dateien der Gegenseite. Eine leere
  Quelle bricht den Lauf ab. Siehe [docs/loeschen.md](docs/loeschen.md).
- **Signatur der Artefakte.** Die veröffentlichte DMG ist mit einer Developer ID
  signiert und notarisiert. Prüfbar mit `shasum -a 256 -c SHA256SUMS` und
  `xcrun stapler validate`.

## Was nicht in den Rahmen fällt

- Fehler in `rsync`, `ssh` oder `zip` selbst. Die App ruft die Werkzeuge des
  Systems auf, sie liefert sie nicht mit.
- Fehler, die einen bereits kompromittierten Rechner voraussetzen. Wer lokal
  Code ausführen kann, kommt an den Schlüsselbund, und dagegen kann keine
  Anwendung etwas.

## Unterstützte Fassungen

Nur die jeweils neueste Veröffentlichung. Rückportierungen gibt es nicht.

## Belohnung

Keine. Wer möchte, wird in den Anmerkungen zur Fassung genannt.
