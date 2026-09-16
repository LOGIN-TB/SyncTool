# Mehrere Rechner

Zurück zur [Übersicht](../README.md).

SyncTool ist dafür gebaut, dass mehrere Macs denselben Stammordner gegen
dasselbe Ziel abgleichen. Dieser Text sagt, was dabei zugesichert wird und was
nicht.

## Was zugesichert wird

**Es laufen nie zwei gleichzeitig.** Vor jedem Lauf greift SyncTool eine Sperre
im Ziel, `.synctool/lock/`. Bekommt sie ein anderer Rechner, bricht der Lauf ab
und nennt den Namen des Rechners, der gerade arbeitet. Ohne das könnten zwei
Läufe mit Löschen sich gegenseitig genau die Dateien wegräumen, die der jeweils
andere eben geschrieben hat, und beide schrieben danach einen Bestand, der den
eigenen Stand als gemeinsamen behauptet.

Angelegt wird die Sperre mit `mkdir` ohne `-p`. Das ist auf POSIX atomar: Zwei
Rechner, die gleichzeitig danach greifen, bekommen genau einmal ein Ja. Bei SMB
und NFS ist diese Atomarität eine Zusage des Servers, nicht des Dateisystems.

Eine Sperre, die älter als eine Stunde ist, gilt als liegengeblieben und wird
übernommen. Ein abgestürzter Lauf kann seine nicht aufräumen, und eine Sperre,
die niemand mehr löst, legte das Profil sonst für immer still.

**Löschungen wandern korrekt.** Löscht Rechner A eine Datei und lädt mit Löschen
hoch, sieht Rechner B beim nächsten Prüfen eine Löschung und keinen Neuzugang.
Er lädt sie nicht wieder hoch. Dafür sorgt das Gedächtnis, das jeder Rechner für
sich führt: Es beantwortet die Frage, ob *dieser* Rechner den Pfad beim letzten
Abgleich schon hatte.

Genau deshalb steht dieses Gedächtnis lokal und nicht auf dem Ziel. Der Bestand
eines anderen Rechners beantwortet die Frage falsch: Eine Datei, die A gerade
erst hochgeladen hat, stünde in As Bestand, und B, der sie nie hatte, hielte sie
für eine, die er selbst gelöscht hat. Statt sie herunterzuladen, böte er an, sie
drüben wegzuräumen.

**Man sieht, wer zuletzt gelaufen ist.** Auf dem Ziel liegt `.synctool/stand.json`
mit dem Namen des Rechners und dem Zeitpunkt. Steht dort ein anderer Rechner,
zeigt das Statusfenster es an. Entschieden wird daran nichts, die Angabe
beantwortet nur die Frage, die man sich stellt: Ist mein Stand der aktuelle?

**Das Ziel wird wiedererkannt.** Beim Verbindungstest legt SyncTool
`.synctool-ziel` mit einer Kennung ab und merkt sie sich im Profil. Passt die
Kennung später nicht, bricht der Lauf ab, bevor er etwas anfasst. Der
gefährlichste Fall braucht dafür keinen Fehler in der App: Die Platte ist nicht
verbunden, und an ihrer Stelle steht ein leerer Ordner mit demselben Pfad. Die
Kennung wandert nicht mit, sonst könnte sie zwei Ordner nicht auseinanderhalten.

## Was nicht zugesichert wird

**Das ist kein Mehrschreiber-Sync.** Zwei Rechner, die dieselbe Datei ändern,
erzeugen einen Konflikt. SyncTool zeigt ihn an und fasst die Datei in keiner
Richtung an. Beide Fassungen bleiben, wo sie sind, bis jemand entscheidet.
Zusammengeführt wird von Hand.

Das ist ehrlicher als jede Automatik. Wer automatisch zusammenführen will,
braucht ein Werkzeug, das den Inhalt versteht, und für Quelltext gibt es das
schon: git.

**Es gibt keine gemeinsame Uhr.** Zwischen mehreren Macs und der Gegenstelle
entscheidet bei einseitiger Arbeit der Zeitstempel. Eine Datei mit voreilender
Änderungszeit, etwa aus einem entpackten Archiv oder von einem Rechner mit
falsch gestellter Uhr, gewinnt dauerhaft gegen jede echte spätere Bearbeitung.

**Ein Abgleich ist kein Backup.** Wer eine Datei versehentlich löscht und
hochlädt, hat sie auch auf der Gegenseite verloren. Was ein Lauf ersetzt oder
löscht, liegt zwar 30 Tage unter `.synctool-versionen/`, siehe
[loeschen.md](loeschen.md), aber darauf ist kein Sicherungskonzept zu bauen.
Dafür gibt es das Archiv, siehe [backup.md](backup.md).

## Die eigenen Dateien der App im Ziel

| Pfad | Zweck |
| --- | --- |
| `.synctool-ziel` | Kennung, an der sich der Ordner wiedererkennen lässt |
| `.synctool/lock/` | Sperre, solange ein Lauf arbeitet |
| `.synctool/stand.json` | Wer zuletzt gelaufen ist und wann |
| `.synctool-versionen/` | Was Läufe ersetzt oder gelöscht haben, 30 Tage |
| `.synctool-partial/` | Teildateien eines laufenden Transfers |

Alle sind vom Abgleich ausgenommen und wandern nie auf einen Rechner. Bei rsync
ist ein ausgeschlossener Eintrag zugleich vor `--delete` geschützt, kein Lauf
räumt sie also weg.
