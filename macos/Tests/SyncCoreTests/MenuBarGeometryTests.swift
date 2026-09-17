import CoreGraphics
import Foundation
import Testing

@testable import SyncCore

@Suite("Lage des Menüleisten-Fensters")
struct MenuBarGeometryTests {
    /// Ein Bildschirm 1440 hoch, Menüleiste 25 Punkt: sichtbar bleibt 0…1415.
    private let sichtbar = CGRect(x: 0, y: 0, width: 2560, height: 1415)

    /// Der gemeldete Fehler, als Rechnung.
    ///
    /// Das Fenster steht mit der Oberkante bei 1409 und ist 400 hoch. Klappt
    /// ein Abschnitt auf, wird es 650 hoch. AppKit laesst dabei den Ursprung
    /// stehen, also wandert die Oberkante von 1409 auf 1659, weit ueber den
    /// Bildschirmrand hinaus.
    @Test("Beim Aufklappen bleibt die Oberkante, wo sie war")
    func theTopEdgeStaysWhereItWas() {
        let oben: CGFloat = 1409
        let vorher = CGPoint(x: 100, y: oben - 400)
        let nachher = MenuBarGeometry.origin(
            currentOrigin: vorher, height: 650, anchorTop: oben, visibleFrame: sichtbar
        )
        #expect(nachher.y + 650 == oben)
        // Und seitlich wird nichts angefasst: Die Breite ändert sich nie.
        #expect(nachher.x == vorher.x)
    }

    @Test("Beim Zuklappen ebenso")
    func andTheSameOnTheWayBack() {
        let oben: CGFloat = 1409
        let vorher = CGPoint(x: 100, y: oben - 650)
        let nachher = MenuBarGeometry.origin(
            currentOrigin: vorher, height: 400, anchorTop: oben, visibleFrame: sichtbar
        )
        #expect(nachher.y + 400 == oben)
    }

    /// Mehrere aufgeklappte Abschnitte reichen zusammen unter den Rand. Lieber
    /// ein Fenster, das unten anstoesst, als eines, dessen Fussleiste nicht
    /// mehr erreichbar ist.
    @Test("Ein zu hohes Fenster wird nach unten geklemmt")
    func anOverlyTallWindowIsClamped() {
        let nachher = MenuBarGeometry.origin(
            currentOrigin: CGPoint(x: 100, y: 500), height: 2000,
            anchorTop: 1409, visibleFrame: sichtbar
        )
        #expect(nachher.y == sichtbar.minY)
    }

    /// Der Punkt, an dem der zweite Anlauf gescheitert ist: Ohne gemessene
    /// Oberkante wurde gar nicht korrigiert, und das Fenster wanderte.
    @Test("Ohne gemessene Oberkante zählt die Menüleiste")
    func withoutAMeasurementTheMenuBarCounts() {
        let oben = MenuBarGeometry.anchorTop(measured: nil, visibleFrame: sichtbar)
        #expect(oben == sichtbar.maxY - MenuBarGeometry.assumedGap)
        // Und damit landet das Fenster dicht unter der Menüleiste, nicht
        // irgendwo. Ein paar Punkte daneben sind kein Vergleich zu mehreren
        // hundert.
        #expect(abs(oben - sichtbar.maxY) < 20)
    }

    @Test("Eine gemessene Oberkante hat Vorrang")
    func aMeasuredTopEdgeWins() {
        #expect(MenuBarGeometry.anchorTop(measured: 1409, visibleFrame: sichtbar) == 1409)
    }

    /// Der Fall, der den vierten Anlauf hätte retten können.
    ///
    /// Merkt sich der Anker einmal eine Kante, die schon verrutscht ist, dann
    /// zieht er das Fenster bei jeder weiteren Änderung genau dorthin zurück
    /// und schreibt den Fehler fest. Eine Kante weit weg von der Menüleiste ist
    /// deshalb keine Kante, sondern ein Messfehler.
    @Test("Eine verrutschte Oberkante wird verworfen")
    func aDriftedTopEdgeIsDiscarded() {
        let verrutscht = sichtbar.maxY - 500
        let oben = MenuBarGeometry.anchorTop(measured: verrutscht, visibleFrame: sichtbar)
        #expect(oben == sichtbar.maxY - MenuBarGeometry.assumedGap)
    }

    /// Woran der Anker das Menüleisten-Fenster überhaupt erkennt.
    ///
    /// Vorher hing das an `Breite == 460`, also an einer Zahl aus der Ansicht.
    /// Sie stimmte nicht, und im Protokoll stand danach gar nichts mehr.
    @Test(
        "An der Menüleiste hängt, was dicht darunter sitzt",
        arguments: [
            (0.0, true), (2.0, true), (40.0, true), (40.5, false), (300.0, false),
        ] as [(CGFloat, Bool)]
    )
    func whatCountsAsHangingAtTheMenuBar(abstand: CGFloat, erwartet: Bool) {
        #expect(
            MenuBarGeometry.hangsAtMenuBar(
                top: sichtbar.maxY - abstand, visibleFrame: sichtbar
            ) == erwartet
        )
    }

    /// Ein Fenster, das über die Menüleiste hinausragt, hängt nicht daran.
    @Test("Über der Menüleiste zählt nicht")
    func aboveTheMenuBarDoesNotCount() {
        #expect(!MenuBarGeometry.hangsAtMenuBar(top: sichtbar.maxY + 50, visibleFrame: sichtbar))
    }

    /// Die Obergrenze fuer den Mittelteil.
    ///
    /// Das ist der eigentliche Fehler gewesen: Vier aufgeklappte Abschnitte
    /// zusammen reichten weiter, als Platz war, und ab dort rueckt macOS das
    /// Fenster nach oben weg. Beim Zuklappen rueckt es nicht zurueck. Bleibt
    /// das Fenster unter der Bildschirmhoehe, stellt sich die Frage nie.
    @Test(
        "Der Mittelteil bleibt im Bildschirm",
        arguments: [
            (1415.0, 520.0),  // grosser Bildschirm: die Wunschhöhe
            (900.0, 520.0),  // Notebook: immer noch die Wunschhöhe
            (700.0, 500.0),  // klein: der Bildschirm entscheidet
            (400.0, 240.0),  // sehr klein: die Untergrenze gewinnt
        ] as [(CGFloat, CGFloat)]
    )
    func theContentStaysOnScreen(hoehe: CGFloat, erwartet: CGFloat) {
        let schirm = CGRect(x: 0, y: 0, width: 2560, height: hoehe)
        #expect(MenuBarGeometry.maxContentHeight(visibleFrame: schirm) == erwartet)
    }

    /// Die Zusage, auf die es ankommt: Fenster plus Rahmenwerk passen auf den
    /// Bildschirm, sonst waere nichts gewonnen.
    @Test("Inhalt plus Rahmenwerk passen auf den Bildschirm")
    func contentPlusChromeFitsTheScreen() {
        let hoehen: [CGFloat] = [1415, 1080, 900, 700, 500]
        for hoehe in hoehen {
            let schirm = CGRect(x: 0, y: 0, width: 2560, height: hoehe)
            let inhalt = MenuBarGeometry.maxContentHeight(visibleFrame: schirm)
            #expect(inhalt + MenuBarGeometry.chromeHeight <= hoehe)
        }
    }

    /// Ohne Schwelle setzt jede Rundung einen neuen Frame, der wieder eine
    /// Benachrichtigung ausloest, die wieder einen Frame setzt.
    @Test("Bruchteile eines Punktes lösen keine Verschiebung aus")
    func fractionsOfAPointDoNotMove() {
        let a = CGPoint(x: 0, y: 1000)
        #expect(!MenuBarGeometry.worthMoving(from: a, to: CGPoint(x: 0, y: 1000.3)))
        #expect(MenuBarGeometry.worthMoving(from: a, to: CGPoint(x: 0, y: 1002)))
        // Schon gestanden heißt: nichts zu tun.
        #expect(!MenuBarGeometry.worthMoving(from: a, to: a))
    }

    /// Zwei Durchgaenge hintereinander duerfen nicht wandern. Genau daran ist
    /// der erste Anlauf gescheitert: Er hat seine eigene Korrektur gemessen und
    /// den Fehler dadurch festgeschrieben.
    @Test("Wiederholtes Auf- und Zuklappen wandert nicht")
    func repeatedTogglingDoesNotDrift() {
        let oben: CGFloat = 1409
        var punkt = CGPoint(x: 100, y: oben - 400)
        for hoehe in [650, 400, 900, 400, 650, 400].map(CGFloat.init) {
            punkt = MenuBarGeometry.origin(
                currentOrigin: punkt, height: hoehe, anchorTop: oben, visibleFrame: sichtbar
            )
            #expect(punkt.y + hoehe == oben)
        }
    }
}

@Suite("Grosse Eingaben an einen Prozess")
struct CommandRunnerInputTests {
    /// Der Fehler, der die App zum Stillstand brachte.
    ///
    /// Drei Megabyte ueber stdin, waehrend der Kindprozess nach stdout
    /// schreibt. Stand die Eingabe vor den Lesern, verklemmten sich beide
    /// Seiten: Der Puffer von stdout lief voll, der Kindprozess blockierte beim
    /// Schreiben und las deshalb nicht weiter aus stdin, waehrend wir dort noch
    /// schrieben. Ohne den Zeitablauf waere das ein Stillstand ohne Ende.
    ///
    /// `cat` gibt alles, was es liest, direkt wieder aus: Genau die Lage, in
    /// der es klemmt.
    @Test("Drei Megabyte über stdin verklemmen sich nicht", .timeLimit(.minutes(1)))
    func largeInputDoesNotDeadlock() async throws {
        let zeile = String(repeating: "x", count: 99) + "\n"
        let eingabe = String(repeating: zeile, count: 35_000)
        #expect(eingabe.utf8.count > 3_000_000)

        let ergebnis = try await CommandRunner.run(
            executable: "/bin/cat", arguments: [], standardInput: eingabe, timeout: 45
        )
        #expect(ergebnis.succeeded)
        // Alles zurueckgekommen, nichts abgeschnitten.
        #expect(ergebnis.standardOutput.utf8.count == eingabe.utf8.count)
    }

    /// Ohne Eingabe muss die Pipe trotzdem geschlossen werden, sonst wartet
    /// der Kindprozess auf ein Ende, das nie kommt.
    @Test("Ohne Eingabe endet ein lesender Prozess trotzdem", .timeLimit(.minutes(1)))
    func aReadingProcessStillEndsWithoutInput() async throws {
        let ergebnis = try await CommandRunner.run(
            executable: "/bin/cat", arguments: [], timeout: 20
        )
        #expect(ergebnis.succeeded)
        #expect(ergebnis.standardOutput.isEmpty)
    }
}
