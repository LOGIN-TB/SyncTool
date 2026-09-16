# Änderungen

## 1.5.0 (unveröffentlicht)

### Datensicherheit

- **Ein Lauf überträgt genau die Pfade, die die Prüfung seiner Richtung
  zugeordnet hat.** Vorher war das ein voller rsync über den ganzen Baum: Wer
  „Hochladen" drückte, überschrieb damit auch die neuere Fassung der
  Gegenstelle mit der älteren von hier, und jeder gemeldete Konflikt wurde
  einseitig plattgemacht, obwohl direkt daneben stand, dass genau das passiert.
- **Konflikte bleiben unberührt.** Beide Fassungen bleiben, wo sie sind, bis
  jemand entscheidet.
- **Was ersetzt oder gelöscht wird, liegt 30 Tage unter
  `.synctool-versionen/`** auf der Empfängerseite, mit demselben Pfad wie
  vorher. Der Ordner ist vom Abgleich ausgenommen und vor `--delete` geschützt.
  Mit openrsync gilt das nicht beim Löschen, siehe unten.
- **Gelöscht wird in einem eigenen Lauf nach dem Inhalt**, mit `--existing
  --ignore-existing --delete-after`. Eine umbenannte Datei geht so erst unter
  dem neuen Namen hinüber und fällt danach unter dem alten weg.
- **Der letzte Abgleich rückt nur nach einem Lauf vor, der durchlief.** Vorher
  stand er auch nach einem Abbruch auf jetzt, und damit war die
  Konflikterkennung für alles blind, was davor lag: Statt einer Rückfrage
  entschied stillschweigend der jüngere Zeitstempel. Gespeichert wird jetzt der
  Zeitpunkt der Prüfung, nicht der des Laufendes.
- **Die Löschbremse gilt für jeden Lauf**, nicht nur für den Git-Lauf, und sie
  hat einen zweiten Anschlag: die beim Prüfen gemessene Zahl plus 50. Wer „17
  Dateien löschen?" bestätigt hat, hat nicht hundert erlaubt.
- **Ein unvollständiger Bestandslauf erzeugt keine Löschungen mehr.** Sind
  während der Auflistung Dateien verschwunden (rsync-Status 24), ist die Liste
  zu kurz, und ein fehlender Eintrag sieht aus wie ein gelöschter. Übertragen
  geht weiter, das Statusfenster sagt warum.
- **openrsync löscht nicht, wenn gleichzeitig gesichert wird.** Kein Abbruch,
  keine Meldung, Status 0. SyncTool lässt die Sicherung dort weg und löscht wie
  zugesagt. Mit `brew install rsync` gibt es beides zusammen.
- Schutz- und Filterregeln treffen jetzt auch Pfade mit Backslash. In rsyncs
  Filtersprache ist er selbst das Maskierzeichen; eine Schutzregel für einen
  solchen Namen ging vorher ins Leere, und `--delete` räumte genau die Datei
  weg, die sie schützen sollte.

### Statusfenster

- **Das Fenster bleibt unter seinem Symbol**, auch wenn Abschnitte auf- und
  zugeklappt werden. Vorher wanderte die Oberkante mit jeder Höhenänderung.
- **Der Unterschied zwischen den beiden Bestandszahlen ist belegt statt
  behauptet.** Vorher verglich die App zwei Zahlen: Zieh die Repos ab, dann
  muss dieselbe Zahl übrigbleiben. Das ist keine Aussage, sondern eine Wette.
  Lag eine Datei nur auf dem Server und eine andere nur hier, hoben sich die
  beiden Abweichungen in der Rechnung auf, und die Anzeige behauptete, die
  Differenz läge in den Repos. Jetzt steht je Repo die Zahl beider Seiten mit
  ihrer Differenz da, und was das nicht erklärt, steht als Pfadliste darunter.

### Git-Repos

- **`.git/` geht als Einheit über die Leitung.** Bisher wurde jede Datei darin
  einzeln abgeglichen. Weil ein Repo aus Dateien besteht, die beide Rechner
  schreiben, kamen nur die reinen Neuzugänge an, während `refs/heads/*`,
  `logs/HEAD` und `packed-refs` stehenblieben. Danach meldete git „N commits
  behind", obwohl der Abgleich sauber durchgelaufen war.
- Im Statusfenster steht je Repo eine Zeile statt tausender `.git`-Pfade.
- Läuft ein Repo auf beiden Seiten auseinander, bleibt es in diesem Lauf
  unberührt und wird gemeldet.
- Der Lauf für die Repos löscht innerhalb von `.git/`, auch ohne Löschhaken,
  und nur dort. Er hat eine eigene Notbremse aus der Messung des Prüflaufs.
- **Abgleich mit der Gegenstelle.** Nach jeder Übertragung holt SyncTool je Repo
  von dort und spult vor, soweit das ohne Zusammenführen geht. Vorher wandert
  der Repo-Ordner in ein Zip. Gepusht wird nie.
- Unter „Programm, Allgemein" steht, welches git gefunden wurde.

- **Verglichen werden die Zeiger, nicht die Dateien.** git packt von sich aus
  um, und danach haben beide Rechner dieselben Commits in verschieden benannten
  Packdateien. Datei für Datei sah das aus wie beidseitige Arbeit: das Repo
  galt als auseinandergelaufen, beide Knöpfe waren grau, und in der App gab es
  keinen Weg weiter. Der Prüflauf holt jetzt `HEAD`, `packed-refs` und `refs/`
  auch von der Gegenseite und entscheidet daran. Gleicher Stand heißt: nichts zu
  tun, und die Packdateien wandern auch nicht mehr über die Leitung.
- **Die Gegenstelle bricht einen Gleichstand auf.** Steht das Repo hier auf
  ihrem Stand und ist die Arbeitskopie sauber, gewinnt diese Seite, und
  „Hochladen" nimmt das Repo mit.
- Unversionierte Dateien halten den Vorspulschritt nicht mehr auf. Vorher galt
  jeder herumliegende tmp-Ordner als schmutzige Arbeitskopie, und der Schritt
  lief so gut wie nie.
- Die Meldung nach dem Abgleich sagt, was wirklich war. Vorher stand dort „Kein
  Repo hing hinter seiner Gegenstelle zurück", sobald nichts vorgespult wurde,
  auch wenn ein Repo zurückhing und nur ausgelassen werden musste.
- Das Statusfenster zeigt auch Repos, die zum Sync-Ziel passen und trotzdem
  hinter ihrer Gegenstelle hängen. Die standen vorher nirgends.
- Der grüne Haken und die Bestandszahlen widersprechen sich nicht mehr. Die
  Summen zählen weiter roh, damit sie sich gegen einen FTP-Client halten lassen;
  liegt der Unterschied ganz in Repos auf gleichem Stand, steht das jetzt
  darunter und die Zahl bleibt ruhig. Bleibt ein Rest offen, wird sie orange.

Siehe [docs/git.md](docs/git.md).

## 1.4.0 (2026-08-20)

Erste öffentliche Fassung.

### Ziele

- **Anbieterkatalog.** Ein neues Profil fragt zuerst, was das Ziel ist, und
  zeigt danach nur die Felder, die dieses Ziel wirklich braucht. Eine
  NFS-Freigabe fragt nicht nach einem Passwort, ein OneDrive-Ordner nicht nach
  Server und Port.
- **Ziele über SSH hinaus.** Neben Hetzner Storage Box und eigenen Servern
  jetzt auch lokale Ordner: externe Platten, zweite Volumes und die Ordner der
  Anbieter-Clients von Nextcloud, Google Drive, OneDrive und Dropbox. Ein
  solcher Lauf braucht keine Anmeldung, kein Passwort und keinen Host-Key.
- Vorlagen für SMB, NFS und WebDAV stehen im Katalog. Das Einhängen selbst
  kommt in einer der nächsten Fassungen; bis dahin sagt „Verbindung testen",
  dass die Freigabe im Finder verbunden und als lokaler Ordner eingetragen
  werden kann.

### Sicherheit beim Löschen

- **Leere Quelle bricht den Lauf ab.** Ist auf der Quellseite nichts zu finden,
  obwohl beim letzten Abgleich Dateien dort lagen, wird ein Lauf mit Löschen
  abgebrochen statt ausgeführt. Der häufigste Grund ist ein Laufwerk, das nicht
  verbunden ist. Ohne diese Sperre räumt `--delete` die Gegenseite aus.
- Ein fehlender Zielordner bei einem lokalen Ziel bricht ab, statt ihn anzulegen.

### Oberfläche

- Pfade werden mit dem Heimatverzeichnis als Tilde angezeigt, also `~/Projekte`.
  Gespeichert wird weiter der vollständige Pfad.
- Startargumente `--settings`, `--status`, `--general`, `--profile=` und `--tab=`
  öffnen die Fenster direkt. Gedacht für die Bildschirmfotos der Anleitung und
  für die Entwicklung.

### Auslieferung

- **Universal Binary** für Apple Silicon und Intel. Dafür braucht es kein
  Xcode: gebaut wird zweimal und danach mit `lipo` zusammengeführt. Ein hartes
  Tor im Bauskript verhindert, dass eine Auslieferung still auf eine
  Architektur zusammenfällt.
- Signiert mit Developer ID, Hardened Runtime, notarisiert und gestapelt.
- `SYNCTOOL_SUPPORT_DIR` lenkt den Ablageordner um, für Tests und Bildschirmfotos.

### Davor

Vor der Veröffentlichung entstanden über mehrere Fassungen der zweistufige
Ablauf mit getrenntem Prüfen und Übertragen, die Bestandslisten als Antwort auf
„gelöscht oder neu", die Ausschluss-Statistik, das lokale Backup als
Zip-Archiv, die Passwortübergabe über einen Unix-Domain-Socket und die
Host-Key-Prüfung in einem eigenen `known_hosts`. Öffentliche Artefakte gab es
davon nicht.
