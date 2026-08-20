# Entwicklung, Bauen, Ausliefern

Zurück zur [Übersicht](../README.md).

## Aufbau des Repos

```
SyncTool/
├── macos/          die App: Package.swift, Sources, Tests, Resources, Scripts
├── docs/           Anleitung und Bilder
└── Makefile        leitet an macos/ weiter
```

Die App liegt in einem Unterordner, damit eine Windows-Fassung später daneben
passt, ohne dass etwas umziehen muss. Die gewohnten Aufrufe funktionieren vom
Wurzelverzeichnis aus unverändert.

`macos/Sources/SyncCore` ist die Bibliothek und enthält die gesamte Logik. Von
33 Dateien sind 31 reines Foundation, ohne AppKit und ohne SwiftUI.
`macos/Sources/SyncTool` ist die Oberfläche. Diese Trennung ist der Grund, warum
eine Windows-Fassung überhaupt denkbar ist.

## Bauen

Xcode wird nicht gebraucht, die Command Line Tools reichen.

```bash
make app
```

Legt `macos/build/SyncTool.app` an, als Universal Binary.

```bash
make app-native
```

Der schnelle Weg für die Entwicklung: nur die eigene Architektur, Debug-Bau.
`make run` macht dasselbe und startet die App danach.

```bash
make test
```

Braucht `Testing.framework`. Das Makefile setzt die Suchpfade selbst, weil
SwiftPM sie ohne Xcode nicht findet, und prüft dabei auf das Framework selbst
und nicht auf sein Elternverzeichnis: mit vollem Xcode liegt es an anderer
Stelle und SwiftPM findet es allein.

```bash
make icon
```

Zeichnet das Programmsymbol und legt `macos/Resources/SyncTool.icns` an. Nötig
nur nach einer Änderung an `Scripts/make-icon.swift`. Das Symbol wird bewusst
gezeichnet und nicht aus SF Symbols genommen: Apples Lizenz erlaubt die Symbole
in einer Oberfläche, nicht als Programmsymbol.

## Universal Binary ohne Xcode

Der naheliegende Weg `swift build --arch arm64 --arch x86_64` braucht `xcbuild`
aus einem vollen Xcode. Mit blossen Command Line Tools gibt es das nicht, und
der frühere Zweig im Bauskript wurde deshalb nie genommen: jeder so gebaute
Stand war stillschweigend arm64-only und lief auf keinem Intel-Mac.

Stattdessen wird zweimal gebaut und danach zusammengeführt:

```bash
swift build -c release --triple arm64-apple-macosx14.0  --scratch-path .build-arm64
swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build-x86_64
lipo -create <arm64>/SyncTool <x86_64>/SyncTool -output …/Contents/MacOS/SyncTool
```

Das funktioniert, weil das SDK die Swift-Schnittstellen für x86_64 mitbringt und
das Paket keine Abhängigkeiten und keine Makro-Plugins hat.

Danach zwei Prüfungen, und zwar als **hartes Tor**, nicht als Meldung:

- `lipo -archs` muss beide Architekturen nennen.
- `otool -l | grep minos` muss in **beiden** Scheiben 14.0 zeigen. Eine
  abweichende Untergrenze in einer Scheibe hebt still die Anforderung für
  Intel-Nutzer, und auf einem Apple-Silicon-Rechner fällt das niemandem auf.

`NATIVE_ONLY=1` überspringt das alles.

## Signieren und Notarisieren

Nötig ist eine bezahlte Apple-Developer-Mitgliedschaft und ein Zertifikat
**Developer ID Application**. Einmalig:

1. Schlüsselbundverwaltung, Zertifikatsassistent, „Von einer
   Zertifizierungsinstanz anfordern", auf die Festplatte speichern, 2048 Bit
   RSA. Das ist der Weg, der ohne Xcode funktioniert.
2. developer.apple.com, Certificates, daraus ein Developer-ID-Application-
   Zertifikat erzeugen, laden, doppelklicken.
3. Prüfen: `security find-identity -v -p codesigning` zeigt genau eine Identität.
4. Das `.p12` als Sicherung exportieren. Geht es verloren, ist es nicht
   wiederherstellbar.
5. Einen App-Store-Connect-API-Schlüssel anlegen und
   `xcrun notarytool store-credentials` einmal laufen lassen. Ein API-Schlüssel
   ist einem app-spezifischen Passwort vorzuziehen, weil er einzeln widerrufbar
   ist.

Danach:

```bash
make release VERSION=1.4.0
```

### Entitlements braucht die App keine

Das ist eine Entscheidung und kein Versäumnis, deshalb steht sie hier.

Die Hardened Runtime beschränkt, was in **diesen** Prozess geladen wird:
Bibliotheken, `DYLD_*`-Variablen, ausführbarer Speicher, Debugger. `Process`
lädt nichts, es startet einen neuen Prozess mit eigenem Signierzusammenhang.

Das Starten von `/usr/bin/ssh`, `/usr/bin/zip` und einem Homebrew-rsync braucht
deshalb **kein** `com.apple.security.cs.disable-library-validation` und auch
sonst nichts. Das Homebrew-rsync ist der interessante Fall: es ist ad hoc
signiert, und das genügt auf Apple Silicon zum Starten. Wäre es ein Plugin, das
in unseren Adressraum geladen wird, wäre es umgekehrt. Wer das Entitlement „zur
Sicherheit" hinzufügt, schwächt die App ohne Gegenwert.

Ebenso wenig kommt `--deep` beim Signieren zum Einsatz. Das ist ein
Prüfschalter, kein Signierschalter, und es würde den zweiten Ausführbaren im
Bundle mit den Flags des Bundles neu signieren.

`com.apple.security.app-sandbox` würde das Starten von `ssh` gegen beliebige
Pfade brechen. `com.apple.security.get-task-allow` lässt die Notarisierung
scheitern.

### Eine Nebenwirkung beim Wechsel der Signatur

Wer die App vorher selbst gebaut hat, hatte eine ad hoc signierte Fassung. Mit
dem Wechsel auf eine Developer-ID-Signatur ändert sich die Identität des
Programms, also fragt macOS beim ersten Passwortzugriff einmal nach dem
Schlüsselbund. Einmal „Immer erlauben", dann ist es still. Bei einer frischen
Installation passiert das nicht.

## Bildschirmfotos

```bash
make app && bash macos/Scripts/screenshots.sh
```

Das Skript baut eine Werkstatt mit ausgedachten Profilen und zwei lokalen
Demo-Ordnern auf und fotografiert die Fenster daraus. Die echte Konfiguration
wird nicht angefasst.

Möglich ist das über `SYNCTOOL_SUPPORT_DIR`. Ein umgebogenes `HOME` würde
**nicht** wirken: `NSHomeDirectory()` kommt aus der Benutzerdatenbank und nicht
aus der Umgebung. Das Skript prüft vor dem Start, ob das Bundle den Schalter
überhaupt kennt, und bricht sonst ab, statt Bilder mit echten Hostnamen zu
erzeugen.

Ein echter Prüflauf braucht keinen Server, weil lokale Ordner als Ziel möglich
sind: Zugänge, Abgänge und Konflikte entstehen zwischen zwei Ordnern auf dieser
Platte.

Voraussetzung ist die Freigabe „Bildschirmaufnahme" für das Programm, das das
Skript startet. Ohne sie scheitert `screencapture`, und zwar leise: deshalb
prüft das Skript jede erzeugte Datei auf Größe.

Ein Bild bleibt Handarbeit: das Popover der Menüleiste. Unter macOS 14 lässt
sich eine `MenuBarExtra` nicht ohne private Schnittstellen von außen öffnen.

## Startargumente

Gedacht für die Werkstatt und für die Entwicklung, wo der Griff in die
Menüleiste bei jedem Start lästig ist.

| Argument | Wirkung |
| --- | --- |
| `--settings` | öffnet die Einstellungen |
| `--status` | zeigt die Statusansicht als Fenster |
| `--general` | öffnet die Einstellungen bei „Programm, Allgemein" |
| `--profile=<Name>` | wählt ein Profil zum Bearbeiten, Namensanfang genügt |
| `--tab=verbindung\|abgleich\|backup` | wählt den Reiter vor |

Ohne Argument bleibt alles zu: die App ist eine Menüleisten-App und soll beim
Anmelden nichts aufmachen.

## Umgebungsvariablen

| Variable | Wirkung |
| --- | --- |
| `SYNCTOOL_SUPPORT_DIR` | verlegt den Ablageordner, für Tests und Bildschirmfotos |
| `SYNCTOOL_KEEP_VERSION=1` | hält die Baunummer an |
| `NATIVE_ONLY=1` | baut nur die eigene Architektur |
| `SIGN_IDENTITY` | signiert mit Developer ID statt ad hoc |
| `SYNCTOOL_TODAY` | setzt das Datum der Baunummer, für Tests |
