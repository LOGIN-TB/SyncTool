# Git-Repos

Zurück zur [Übersicht](../README.md).

Ein Git-Repo ist keine Menge unabhängiger Dateien. `refs/`, `logs/`,
`packed-refs`, `index` und `objects/` ergeben nur zusammen einen Stand. Wer sie
einzeln abgleicht, bekommt reproduzierbar einen Mischzustand: die reinen
Neuzugänge kommen an, Objekte und Packfiles, und genau die Dateien bleiben
stehen, die beide Rechner schreiben. Danach meldet git zu Recht „N commits
behind", obwohl der Abgleich sauber durchgelaufen ist.

Deshalb geht `.git/` als Einheit über die Leitung.

## Wie ein Repo erkannt wird

Aus den Pfaden der beiden Bestandslisten, ohne `git` aufzurufen. Alles, was
unterhalb eines vollständigen Segments `.git/` liegt, gehört zum Repo darüber.
Über das Segment und nicht über „enthält .git", sonst schlügen `.gitignore` und
`.github/` mit an.

- **Verschachtelte Repos** ergeben getrennte Einheiten. `a/.git/` und
  `a/b/.git/` überlappen nicht.
- **Submodule** und verknüpfte Arbeitsverzeichnisse haben statt eines Ordners
  eine Datei `.git` mit einer Zeile `gitdir: …`. Die echten Daten liegen unter
  `<oberprojekt>/.git/modules/…` und gehören damit zum Zweig des Oberprojekts.
  Die Verweisdatei selbst bleibt ein gewöhnlicher Eintrag.
- **Blanke Repos** (`spiegel.git/` mit `HEAD` und `objects/` direkt darin)
  werden an diesen beiden Einträgen erkannt.

## Verglichen werden die Zeiger, nicht die Dateien

git packt von sich aus um, nach jedem `fetch` und nach genug Commits. Danach
haben beide Rechner dieselben Commits in verschieden benannten Packdateien.
Ein Vergleich Datei für Datei hält das für beidseitige Arbeit, und das Repo
gälte als auseinandergelaufen, obwohl sich nichts geändert hat. Weil git das
von allein tut, wäre das kein Sonderfall, sondern der Normalzustand.

Deshalb holt der Prüflauf `HEAD`, `packed-refs` und alles unter `refs/` auch von
der Gegenseite, ein paar Kilobyte je Repo, und vergleicht daran. Stehen beide
Seiten auf denselben Zeigern, ist das Repo dasselbe. Es gibt dann nichts zu
tun, und sein `.git` bleibt auch vom Hauptlauf ausgenommen: die frisch
gepackten Dateien jedes Mal über die Leitung zu schicken brächte nichts.

Lässt sich die Gegenseite nicht lesen, bleibt es beim Vergleich über die
Dateien, so wie vorher.

## Vier Zustände

Nach dem Prüfen steht je Repo eine Zeile im Statusfenster statt tausender
`.git`-Pfade:

| Zustand | heißt |
| --- | --- |
| gleicher Stand | dieselben Zeiger auf beiden Seiten, nichts zu tun |
| vom Server holen | nur die Gegenseite hat seit dem letzten Abgleich in `.git` geschrieben |
| zum Server schicken | nur dieser Rechner hat geschrieben |
| läuft auseinander | beide |

Eine Löschung zählt dabei als Schreibbewegung: ein `git gc` auf dem einen
Rechner räumt lose Objekte weg, und das ist eine Änderung wie jede andere.

Läuft ein Repo auseinander, bleibt es in diesem Lauf **unberührt**. Ein halb
übertragenes `.git` ist schlimmer als ein veraltetes.

## Wer einen Gleichstand aufbricht

Bleibt es dabei, dass beide Seiten geschrieben haben, kann der Abgleich allein
nicht entscheiden. Die Gegenstelle kann es: steht das Repo hier auf ihrem Stand
und ist die Arbeitskopie sauber, ist die Frage beantwortet. Diese Seite gewinnt,
und „Hochladen" nimmt das Repo mit.

Verloren geht dabei nichts Einmaliges. Was hier liegt, liegt auch auf der
Gegenstelle, und was nur auf dem Sync-Ziel lag, liegt weiterhin auf dem Rechner,
der es dort hochgeladen hat. Liegen hier dagegen Commits, die noch nirgends
sonst liegen, taugt das nicht als Urteil, und das Repo bleibt liegen.

Ohne einen Lauf gegen die Gegenstelle wird nichts aufgebrochen. Bis dahin bleibt
„läuft auseinander" stehen.

## Zwei rsync-Läufe

Ein Lauf für den ganzen Baum, wie bisher, mit den `.git`-Zweigen als
zusätzliche Ausschlüsse. Danach ein zweiter Lauf nur für die Zweige, die in
diese Richtung gehen.

Der zweite Lauf weicht an zwei Stellen bewusst ab:

**Er löscht innerhalb von `.git/`, auch wenn „Löschen" im Profil aus ist.** Ohne
das überleben auf der Empfängerseite lose Refs, ein alter `packed-refs` und ein
alter `index`, und genau daraus entsteht die Meldung „behind". Geräumt wird
dabei nur, was die Filterdatei aufnimmt: alles andere ist ausgeschlossen, und
ein Ausschluss schützt bei rsync zugleich vor `--delete`. Mehr dazu in
[loeschen.md](loeschen.md).

**Er nimmt die Ausschlussliste des Profils nicht mit.** In einem Zweig, der
gespiegelt wird, hieße `*.log` sonst, dass ein `.git/gc.log` der Empfängerseite
überlebt, und schon wäre das `.git` wieder halb. Siehe
[ausschluesse.md](ausschluesse.md).

Erst der Hauptlauf, dann die Repos. Bricht etwas dazwischen ab, bleibt das
`.git` der Empfängerseite auf seinem alten, in sich stimmigen Stand, und git
meldet geänderte oder unversionierte Dateien. Andersherum zeigten neue Refs auf
eine alte Arbeitskopie, und das sieht aus wie verlorene Arbeit.

## Die Gegenstelle ist das führende System

Das Sync-Ziel hält Dateien vor, den Stand eines Repos hält GitHub. Nach jeder
Übertragung, und auf Knopfdruck auch ohne, geht SyncTool deshalb jedes Repo im
Stammordner durch:

1. `git fetch --prune`
2. Steht der Zweig zurück, ist nichts eigenes dazugekommen und ist die
   Arbeitskopie sauber: sichern, dann `git merge --ff-only`.
3. Alles andere wird gemeldet, nicht geraten. Kein Upstream, abgelöster HEAD,
   ein offener Merge oder Rebase, geänderte versionierte Dateien, eigene Commits
   auf beiden Seiten.

Unversionierte Dateien halten den Vorspulschritt **nicht** auf. Wer in einem
Entwicklungsordner arbeitet, hat fast immer welche herumliegen, und mit ihnen
als Hinderungsgrund liefe dieser Schritt so gut wie nie. Das Netz darunter
bleibt: würde ein ankommender Commit eine davon überschreiben, verweigert
`git merge --ff-only` von sich aus, und der Grund steht in der Zeile des Repos.

Im Statusfenster steht jedes Repo, das eine Handlung oder eine Erklärung
braucht, auch eines, das zum Sync-Ziel passt und trotzdem hinter seiner
Gegenstelle hängt. Was auf Stand ist, bleibt draußen.

Gepusht wird nie. Liegen hier Commits, die noch nirgends sonst liegen, steht das
in der Zeile des Repos, und der `git push` bleibt eine Handbewegung.

Nach einem Vorspulschritt hat sich `.git` hier geändert. Das folgende Prüfen
zeigt das als ausgehend, und der nächste „Hochladen" bringt das Sync-Ziel nach.

`git` wird ohne Rückfragen gestartet: `GIT_TERMINAL_PROMPT=0` und ein `GIT_ASKPASS`,
das sofort fehlschlägt. Eine Menüleisten-App startet nicht aus der Shell, und
ein `git fetch`, das auf eine Eingabe wartet, die nie kommt, hinge für immer.
Ein gescheitertes Holen hält die anderen Repos nicht auf, es steht in der Zeile
des betroffenen.

Welches git gefunden wurde, steht unter „Programm, Allgemein". Ohne git läuft
der Abgleich mit dem Sync-Ziel weiter, nur dieser Schritt entfällt.

## Vor jedem Eingriff wird gesichert

Bevor SyncTool ein Repo vorspult, wandert der Repo-Ordner in ein Zip im
Backup-Ordner des Profils, benannt wie jede andere Sicherung:
`Projekt-bak-2026-09-14.zip`, sortierbar, überschrieben wird nie. Fehlt der
Zielordner im Profil, unterbleibt der Eingriff. Ohne Sicherung kein Eingriff.

Der Schnappschuss nimmt `.git` mit und hält sich sonst an die Ausschlussliste
des Profils: sonst läge `node_modules` in jeder Sicherung, und das Sichern
dauerte länger als der Eingriff, vor dem es schützt.

## Prüfsummen einschalten

Ein Ref ist immer gleich lang. Ohne Prüfsummenvergleich entscheiden Größe und
Zeitstempel, und zwei Refs mit gleicher Länge und Zeitstempeln innerhalb einer
Sekunde gälten als gleich. Für Repos gehört das Häkchen „Prüfsumme" im Profil
deshalb an. Siehe [rsync.md](rsync.md).

## Ein Repo geraderücken

Für Repos, die schon im Mischzustand sind, bevor diese Fassung lief. Je Repo:

1. Ein Zip vom Repo-Ordner ziehen, von Hand oder über „Backup".
2. Lage aufnehmen:

   ```bash
   git status && git log --oneline origin/main..main && git stash list
   ```

3. Keine eigenen Commits, Arbeitskopie sauber: das ist der ganze Fix.

   ```bash
   git merge --ff-only origin/main
   ```

   Die Objekte sind schon da, sie kamen mit dem Abgleich. Der Befehl verschiebt
   nur `refs/heads/main` dorthin, wo sie liegen. Kein Netz nötig.

4. Eigene Commits: `git rebase origin/main` oder `git merge origin/main`,
   auflösen, von hier aus pushen.

5. Kopierartefakte des Finders wegräumen. Das sind Dateien wie `.git/index 2`
   oder `.git/index 3`, die kein git jemals angelegt hat:

   ```bash
   find . -path "*/.git/*" -name "* [0-9]" -print
   ```

   Nach dem Löschen `git status` laufen lassen, das baut den Index neu.

6. `git fsck`, dann in SyncTool „Prüfen". Danach muss das Repo sauber oder
   einseitig sein.
