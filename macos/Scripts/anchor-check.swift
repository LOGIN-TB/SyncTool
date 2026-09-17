// Prueft, ob das Menueleisten-Fenster beim Auf- und Zuklappen oben haengen
// bleibt.
//
// Warum ein eigenes Programm und kein Test: Die Sache haengt an einem echten
// `NSWindow` und an AppKits Benachrichtigungen, und beides gibt es im Testziel
// nicht. Die reine Rechnung steht in `MenuBarGeometryTests`; hier geht es um
// die Mechanik drumherum, und genau daran sind vier Anlaeufe gescheitert:
//
//  1. Der Abstand zur Menueleiste wurde gemessen, bevor SwiftUI positioniert
//     hatte. Die erste Korrektur machte den falschen Wert zur Wahrheit.
//  2. Der Anker wartete auf `didMove` und `didBecomeKey`. Beide koennen
//     ausbleiben, und dann wurde nie korrigiert.
//  3. Der Anker hing an einer nullgrossen Hintergrundansicht. Sie wurde einmal
//     eingehaengt, danach kam keine Groessenaenderung mehr an.
//  4. Der Anker hoerte prozessweit zu, erkannte das Fenster aber an
//     `Breite == 460` und `isVisible`. Beide Merkmale waren geraten, und im
//     Protokoll stand danach keine einzige Nachfuehrung mehr.
//
// Aufruf:
//
//     make anchor-check
//
// Erzeugt Fenster derselben Bauart wie das Popover, aendert mehrfach die Hoehe
// und prueft, ob die Oberkante steht. Die Fenster sind leer und verschwinden
// mit dem Programm.
import AppKit

@MainActor
final class Pruefung {
    private var fehler: [String] = []

    func meldung(_ text: String) { print(text) }

    func fehlschlag(_ text: String) {
        fehler.append(text)
        print("FEHLER: \(text)")
    }

    func abschluss() -> Never {
        if fehler.isEmpty {
            print("OK: die Oberkante haelt.")
            exit(0)
        }
        exit(1)
    }
}

/// Ein Fenster wie das Popover: rahmenlos, nicht aktivierend, dicht unter der
/// Menueleiste.
@MainActor
func popoverAehnlich(breite: CGFloat, oben: CGFloat, hoehe: CGFloat, x: CGFloat) -> NSPanel {
    let fenster = NSPanel(
        contentRect: NSRect(x: x, y: oben - hoehe, width: breite, height: hoehe),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false
    )
    fenster.isFloatingPanel = true
    fenster.orderFront(nil)
    return fenster
}

@MainActor
func warte(_ sekunden: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(sekunden))
}

@MainActor
func lauf() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    guard let screen = NSScreen.main else {
        print("Kein Bildschirm gefunden.")
        exit(1)
    }
    let p = Pruefung()
    let oben = screen.visibleFrame.maxY - MenuBarGeometry.assumedGap

    // Bewusst nicht 460: Genau diese Zahl hat den vierten Anlauf zu Fall
    // gebracht. Ein Fenster, das der Anker nur an seiner Breite erkennt, faellt
    // hier durch.
    let breite: CGFloat = 472
    let fenster = popoverAehnlich(breite: breite, oben: oben, hoehe: 164, x: 300)

    let keeper = MenuBarWindowKeeper()
    keeper.start()
    warte(0.4)

    func pruefe(_ hoehe: CGFloat, _ was: String) {
        let vorher = fenster.frame
        // So aendert AppKit die Groesse: Der Ursprung bleibt, die Oberkante
        // wandert. Genau das soll der Keeper zurueckdrehen.
        fenster.setFrame(
            NSRect(x: vorher.origin.x, y: vorher.origin.y, width: breite, height: hoehe),
            display: true
        )
        warte(0.5)
        let ist = fenster.frame.maxY
        let ab = abs(ist - oben)
        p.meldung(
            String(
                format: "%@: Hoehe %.0f, Oberkante %.0f (Soll %.0f, ab %.1f)",
                was, hoehe, ist, oben, ab))
        if ab > 1 { p.fehlschlag("\(was): Oberkante \(Int(ist)) statt \(Int(oben))") }
    }

    pruefe(700, "aufklappen")
    pruefe(164, "zuklappen")
    pruefe(900, "weit aufklappen")
    pruefe(300, "halb zu")
    pruefe(700, "wieder auf")

    // Der Zeitgeber allein muss es auch schaffen. Dafuer wird das Fenster ohne
    // Benachrichtigung verschoben: `setFrameOrigin` meldet zwar `didMove`, aber
    // der Anker merkt sich daraus keine verrutschte Kante mehr, und danach ist
    // nur noch der regelmaessige Blick uebrig, der es zurueckholt.
    fenster.setFrameOrigin(NSPoint(x: fenster.frame.origin.x, y: fenster.frame.origin.y - 120))
    warte(1.0)
    let nachSchubs = fenster.frame.maxY
    p.meldung(String(format: "nach Schubs: Oberkante %.0f (Soll %.0f)", nachSchubs, oben))
    if abs(nachSchubs - oben) > 1 {
        p.fehlschlag("nach Schubs: Oberkante \(Int(nachSchubs)) statt \(Int(oben))")
    }

    // Und was nicht an der Menueleiste haengt, bleibt unangetastet. Sonst zoege
    // der Anker jedes rahmenlose Fenster der App unter die Leiste.
    let mitte = popoverAehnlich(
        breite: 400, oben: screen.visibleFrame.midY, hoehe: 200, x: 900)
    warte(0.5)
    let vorherMitte = mitte.frame
    mitte.setFrame(
        NSRect(
            x: vorherMitte.origin.x, y: vorherMitte.origin.y, width: 400, height: 500),
        display: true)
    warte(1.0)
    if abs(mitte.frame.origin.y - vorherMitte.origin.y) > 1 {
        p.fehlschlag(
            "Fenster in der Bildschirmmitte wurde verschoben: y \(Int(vorherMitte.origin.y)) "
                + "→ \(Int(mitte.frame.origin.y))")
    } else {
        p.meldung("Fenster in der Bildschirmmitte: unberuehrt, richtig.")
    }

    p.abschluss()
}

MainActor.assumeIsolated { lauf() }
