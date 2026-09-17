// Prueft, ob das Menueleisten-Fenster beim Auf- und Zuklappen oben haengen
// bleibt.
//
// Warum ein eigenes Programm und kein Test: Die Sache haengt an einem echten
// `NSWindow` und an AppKits Benachrichtigungen, und beides gibt es im Testziel
// nicht. Die reine Rechnung steht in `MenuBarGeometryTests`; hier geht es um
// die Mechanik drumherum, und genau daran sind drei Anlaeufe gescheitert:
//
//  1. Der Abstand zur Menueleiste wurde gemessen, bevor SwiftUI positioniert
//     hatte. Die erste Korrektur machte den falschen Wert zur Wahrheit.
//  2. Der Anker wartete auf `didMove` und `didBecomeKey`. Beide koennen
//     ausbleiben, und dann wurde nie korrigiert.
//  3. Der Anker hing an einer nullgrossen Hintergrundansicht. Sie wurde einmal
//     eingehaengt, danach kam keine Groessenaenderung mehr an.
//
// Aufruf:
//
//     make anchor-check
//
// Erzeugt ein Fenster derselben Bauart wie das Popover, aendert fuenfmal die
// Hoehe und prueft, ob die Oberkante steht. Das Fenster ist leer und
// verschwindet mit dem Programm.
import AppKit

@MainActor
func lauf() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    guard let screen = NSScreen.main else {
        print("Kein Bildschirm gefunden.")
        exit(1)
    }
    let breite = MenuBarWindowKeeper.windowWidth
    let oben = screen.visibleFrame.maxY - MenuBarGeometry.assumedGap

    let fenster = NSPanel(
        contentRect: NSRect(x: 300, y: oben - 164, width: breite, height: 164),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false
    )
    fenster.isFloatingPanel = true
    fenster.orderFront(nil)

    let keeper = MenuBarWindowKeeper()
    keeper.start()

    var fehler: [String] = []
    func pruefe(_ hoehe: CGFloat, _ was: String) {
        let vorher = fenster.frame
        // So aendert AppKit die Groesse: Der Ursprung bleibt, die Oberkante
        // wandert. Genau das soll der Keeper zurueckdrehen.
        fenster.setFrame(
            NSRect(x: vorher.origin.x, y: vorher.origin.y, width: breite, height: hoehe),
            display: true
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let ist = fenster.frame.maxY
        let ab = abs(ist - oben)
        print(String(format: "%@: Hoehe %.0f, Oberkante %.0f (Soll %.0f, ab %.1f)",
                     was, hoehe, ist, oben, ab))
        if ab > 1 { fehler.append("\(was): Oberkante \(Int(ist)) statt \(Int(oben))") }
    }

    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    pruefe(700, "aufklappen")
    pruefe(164, "zuklappen")
    pruefe(900, "weit aufklappen")
    pruefe(300, "halb zu")
    pruefe(700, "wieder auf")

    if fehler.isEmpty {
        print("OK: die Oberkante haelt.")
        exit(0)
    }
    for f in fehler { print("FEHLER: \(f)") }
    exit(1)
}

MainActor.assumeIsolated { lauf() }
