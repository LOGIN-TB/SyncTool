# Änderungen

## 1.5.0 (unveröffentlicht)

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
