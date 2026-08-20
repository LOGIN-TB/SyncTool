# Passwortübergabe und Host-Keys

Zurück zur [Übersicht](../README.md).

## Wo das Passwort liegt

Im Schlüsselbund, als Internet-Passwort, gebunden an Server, Port und Benutzer.
Nicht an die Kennung des Profils. Das hat eine Folge, die richtig ist: ein
Duplikat eines Profils hat sein Passwort sofort, und wer Server, Port oder
Benutzer ändert, steht danach ohne Passwort da.

Beim Löschen eines Profils wird das Passwort **nicht** entfernt, wenn ein
anderes Profil denselben Eintrag benutzt.

In `profiles.json` steht kein Passwort.

## Der Weg zu ssh

rsync startet ssh selbst, das Passwort muss also über die Umgebung ankommen.
Naheliegend wäre eine Umgebungsvariable oder eine Datei. Beides ist schlechter
als es aussieht: eine Datei bleibt liegen, wenn ein Prozess abbricht, und in der
Kommandozeile wäre das Passwort über `ps` für jeden Benutzer des Rechners
lesbar.

Der Weg ist deshalb:

1. SyncTool öffnet einen Unix-Domain-Socket in einem eigenen Verzeichnis mit
   Modus 0700.
2. `SSH_ASKPASS` zeigt auf den mitgelieferten Helfer `SyncToolAskpass`,
   `SSH_ASKPASS_REQUIRE=force` erzwingt seine Benutzung (OpenSSH ab 8.4).
   `SYNCTOOL_PW_SOCK` nennt dem Helfer den Socket.
3. ssh fragt, der Helfer holt das Passwort über den Socket und gibt es auf
   stdout aus.

Damit steht das Passwort weder in der Kommandozeile noch in einer Datei noch in
einer Umgebungsvariablen. Umgebungsvariablen eines Prozesses sind nur für
dessen Eigentümer lesbar, die Kommandozeile für alle.

Auf Host-Key-Rückfragen antwortet der Helfer ausdrücklich nicht. Sonst wäre die
Prüfung des Host-Keys mit einem versehentlich durchgereichten „yes" erledigt.

## Warum ein Skript als Remote-Shell

rsync zerlegt den Wert von `-e` an Leerzeichen. Der Pfad zum eigenen
`known_hosts` liegt unter „Application Support", und darin steht ein
Leerzeichen. Deshalb schreibt SyncTool ein kleines Skript in das
Sitzungsverzeichnis und übergibt dessen Pfad. Das Verzeichnis verschwindet mit
der Sitzung.

## Host-Keys

SyncTool führt ein eigenes `known_hosts` unter
`~/Library/Application Support/SyncTool/` und rührt `~/.ssh` nicht an. ssh läuft
mit `StrictHostKeyChecking=yes`: ohne bestätigten Host-Key kommt keine
Verbindung zustande.

„Host-Key prüfen" holt die Kandidaten mit `ssh-keyscan` und zeigt die
Fingerprints. Der Vergleich mit dem, was der Anbieter nennt, ist Handarbeit und
soll es sein: nur dort entsteht das Vertrauen.

## Schlüssel statt Passwort

„SSH-Schlüssel auf dem Server einrichten" legt einmalig ein ed25519-Paar unter
`~/Library/Application Support/SyncTool/` an, hinterlegt den öffentlichen Teil
auf dem Ziel und stellt das Profil auf Schlüssel um. Danach entfällt die
Passwortabfrage, und der Lauf ist schneller und weniger störanfällig.

Bei einer Hetzner Storage Box läuft das über deren eigenen Befehl
`install-ssh-key`, sonst über einen Anhang an `~/.ssh/authorized_keys`.
