# Mitmachen

Fragen und Fehlerberichte gern als Issue. Für Änderungen am Code lohnt vorher
ein Issue, damit niemand an etwas arbeitet, das aus einem anderen Grund so ist,
wie es ist.

## Bauen und prüfen

Xcode wird nicht gebraucht, die Command Line Tools reichen.

```bash
make test
```

Muss vor jedem Pull Request grün sein, vollständig. Der Vorrat an Tests ist
nicht Zierde: er hält die Entscheidungsregeln des Abgleichs fest, und die sind
der Kern der App.

```bash
make app
```

Baut ein Universal Binary und legt es unter `macos/build/SyncTool.app` ab.
`make app-native` ist der schnelle Weg für die Entwicklung.

## Die Regeln, die hier wirklich gelten

**Keine externen Abhängigkeiten.** `Package.swift` hat keine, und das bleibt so.
Das ist eine Entscheidung und kein Versäumnis: die App hantiert mit
Zugangsdaten und mit `--delete`, und jede Abhängigkeit ist eine Stelle, die
jemand anders pflegt. Was das System mitbringt, wird benutzt. Was fehlt, wird
selbst geschrieben oder bleibt weg.

**Kommentare auf Deutsch, ohne Umlaute.** Also `Aenderung`, `laesst`,
`ueberschreiben`. Der ganze Bestand ist so geschrieben, und ein gemischter
Bestand liest sich schlechter als ein durchgehend eigenwilliger.
Oberflächentexte dagegen mit richtigen Umlauten: die liest der Nutzer.

**Kommentare sagen, warum.** Was der Code tut, steht im Code. Was ein Kommentar
beitragen soll, ist der Grund, besonders bei einer Entscheidung, die auf den
ersten Blick falsch aussieht. Beispiel aus `RsyncArguments`: dass dort `-rlptz`
statt `-a` steht, ist ohne den Satz über fehlschlagendes `chown` auf einer
Storage Box nicht nachvollziehbar.

**Testnamen sind deutsche Sätze.** Sie beschreiben die Zusage, nicht die
Funktion:

```swift
@Test("Eine leere Quelle bricht das Löschen ab, bevor rsync startet")
```

Nicht `testEmptySourceThrows`. Wer eine Testliste liest, soll die Regeln der App
daraus lernen können.

**Reine Funktionen, wo es geht.** Die Entscheidungen liegen in Typen ohne
Dateisystem und ohne Netz: `TargetGuard.decide`, `Profile.issues`,
`SyncEndpoints.resolve`, `DriftResolver.resolve`. Nur das Messen fasst die Welt
an. Deshalb lässt sich jede Regel einzeln prüfen, und deshalb laufen die Tests
in Sekunden.

**Kein Umbau ohne Golden-Test.** Wer die rsync-Kommandozeile anfasst, prüft
gegen ein Literal, dass sich für die bestehenden Ziele nichts verschiebt. Ein
zusätzliches Leerzeichen an der falschen Stelle ist dort ein Datenverlust.

## Fassung und Baunummer

`macos/VERSION` hat zwei Zeilen: die Fassung (von Hand) und die Baunummer
(automatisch). **Zeile 2 nie von Hand ändern**, `Scripts/bundle.sh` setzt sie
bei jedem Bau. Wer das umgehen muss, setzt `SYNCTOOL_KEEP_VERSION=1`.

## Bildschirmfotos neu erzeugen

```bash
make app && bash macos/Scripts/screenshots.sh
```

Das Skript baut eine Werkstatt mit ausgedachten Profilen auf und fotografiert
die Fenster daraus. Es fasst die echte Konfiguration nicht an, dafür sorgt
`SYNCTOOL_SUPPORT_DIR`. Das Programm, das das Skript startet, braucht die
Freigabe „Bildschirmaufnahme".

Ein Bild bleibt Handarbeit: das Popover der Menüleiste. Unter macOS 14 lässt es
sich nicht von außen öffnen.

## Was nicht kommt

Damit niemand Arbeit hineinsteckt, die dann abgelehnt wird: kein automatischer
Abgleich, kein Zeitplan, keine Ordnerüberwachung. Der zweistufige Ablauf mit
getrenntem Prüfen und Übertragen ist die Kernaussage der App. Ebenso keine
erweiterten Attribute, keine ACLs und keine automatische Auflösung von
Konflikten.
