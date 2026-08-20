# Änderungen

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
