# Backup

Zurück zur [Übersicht](../README.md).

Ein Abgleich ist kein Backup: er hält beide Seiten auf demselben Stand, und
genau deshalb wandert ein versehentliches Löschen sofort auf die andere Seite.
„Backup" im Statusfenster packt den lokalen Stammordner in ein Zip-Archiv und
legt es in einem Ordner ab, der in den Einstellungen gewählt wird.

Der Lauf ist rein lokal: keine Anmeldung, kein Passwort, keine Verbindung.

## Zielordner

Einstellungen, Reiter „Backup", Knopf „Auswählen". Der Pfad gehört zum Profil,
zwei Profile können in verschiedene Ordner sichern.

Er darf **nicht** im Stammordner liegen, sonst packte das Backup von morgen das
Archiv von heute mit ein. Das wird schon beim Wählen gemeldet, und zwar über die
Dateikennung und die Volumekennung, nicht über einen Textvergleich der Pfade:
sonst ließe sich die Prüfung mit einem Symlink oder mit anderer Groß- und
Kleinschreibung umgehen.

Vor dem Packen wird der freie Platz geprüft.

## Name

`<Ordnername>-bak-<Jahr>-<Monat>-<Tag>.zip`, also etwa
`Projekte-bak-2026-05-23.zip`. Sortierbar, damit alphabetisch gleich
chronologisch ist.

Ein zweites Backup am selben Tag bekommt die Uhrzeit angehängt
(`…-2026-05-23-1430.zip`), ein drittes in derselben Minute eine laufende Nummer.
**Überschrieben wird nie.** Das ist nicht nur Vorsicht: `zip` würde eine
vorhandene Datei nicht ersetzen, sondern erweitern, und das Ergebnis wäre ein
Archiv aus zwei Zeitpunkten.

## Umfang

Alles unterhalb des Stammordners, einschließlich leerer Unterordner und
Symlinks, **einschließlich `node_modules` und `build`**. Draußen bleiben nur
Systemdateien wie `.DS_Store` und die Archive selbst.

Die Ausschlussliste des Profils gilt für den Abgleich, nicht für das Backup.
Siehe [ausschluesse.md](ausschluesse.md).

## Ablauf

Erst wird der Bestand aufgenommen, dann gepackt. Geschrieben wird nach
`<Ziel>/<Name>.zip.part`, erst am Ende wird umbenannt. Ein abgebrochener Lauf
hinterlässt damit kein Archiv, das wie ein fertiges aussieht.

Die Dateiliste geht als **Datei** an `zip`, nicht über eine Pipe. Bei
sechsstellig vielen Pfaden sind das rund 10 MB, und das übersteigt `ARG_MAX`;
über eine Pipe wären Verklemmung und SIGPIPE die Folge.

## Gemessene Zahlen

Gemessen an einem Entwicklungsordner mit 265.910 Einträgen: 6,3 GB roh, 2,8 GB
Archiv, knapp drei Minuten.

Gepackt wird mit Kompressionsstufe 1 statt der Vorgabe 6. Gemessen an 616 MB mit
54.909 Dateien: 13 gegen 21 Sekunden bei 192 gegen 176 MB. Also gut die doppelte
Zeit für ein Zwanzigstel weniger Größe, und ein Entwicklungsordner besteht
ohnehin zu weiten Teilen aus bereits komprimierten Daten.

## Grenzen eines Zip-Archivs

Erweiterte Attribute, Hardlinks und Ressourcezweige wandern nicht mit. Für
Quelltext und Projektdateien spielt das keine Rolle.

Die Archive tragen keine UTF-8-Namensmarkierung, weil Apples `zip` sie nicht
setzen kann. Auf macOS ist das nachweislich egal, beim Entpacken unter Windows
können Umlaute falsch dargestellt werden.
