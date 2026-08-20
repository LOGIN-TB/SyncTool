import AppKit
import SwiftUI
import SyncCore

@main
struct SyncToolApp: App {
    @StateObject private var state = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            StatusView(state: state)
        } label: {
            // Der Anker fuer die Startargumente. Das Symbol der Menueleiste ist
            // das Einzige, was bei einer LSUIElement-App verlaesslich beim Start
            // erzeugt wird: die Fensterszenen entstehen erst, wenn jemand sie
            // oeffnet, und ein `.task` darin liefe deshalb nie.
            Image(systemName: state.menuBarSymbol)
                .task { StartupWindows.open(openWindow, state: state) }
        }
        .menuBarExtraStyle(.window)

        Window("SyncTool – Einstellungen", id: "settings") {
            SettingsView(state: state)
        }
        // `.contentSize` zwaenge das Fenster auf die Groesse des Inhalts und
        // liesse es bei jeder Aenderung springen. Mit einem Mindestmass darf es
        // wachsen, und die Ausschlussliste hat einen Grund dazu.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 880, height: 660)
        .defaultPosition(.center)

        // Dieselbe Ansicht wie im Popover der Menueleiste, nur als Fenster.
        //
        // Zwei Gruende: das Popover einer `MenuBarExtra` laesst sich unter
        // macOS 14 nicht von aussen oeffnen, also braucht die
        // Bildschirmfoto-Werkstatt einen Weg an dieselbe Ansicht. Und im Alltag
        // erspart es den Griff in die Menueleiste. `StatusView` ist mit fester
        // Breite und undurchsichtigem Hintergrund ohnehin fensterfertig.
        Window("SyncTool", id: "status") {
            StatusView(state: state)
        }
        // `.contentSize` und nicht `.contentMinSize`: StatusView hat eine feste
        // Breite, also soll das Fenster genau so breit sein. Mit einem
        // Mindestmass bekaeme es die Vorgabegroesse und stuende mit einem
        // breiten Rand um seinen Inhalt da.
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// Fenster, die beim Start von selbst aufgehen sollen.
///
/// `--settings` oeffnet die Einstellungen, `--status` die Statusansicht als
/// Fenster. Ohne Argument bleibt beides zu, wie bisher: die App ist eine
/// Menueleisten-App und soll beim Anmelden nichts aufmachen.
///
/// Gedacht fuer die Bildschirmfoto-Werkstatt und fuer die Entwicklung, wo der
/// Griff in die Menueleiste bei jedem Start laestig ist. Ohne den Wachposten
/// liefe das bei jedem Erscheinen des Symbols erneut, und ein vom Nutzer
/// geschlossenes Fenster kaeme wieder.
enum StartupWindows {
    private static var done = false

    @MainActor
    static func open(_ openWindow: OpenWindowAction, state: AppState) {
        guard !done else { return }
        done = true

        let arguments = Array(CommandLine.arguments.dropFirst())
        let flags = Set(arguments)

        // Vorwahl vor dem Oeffnen, damit das Fenster gleich richtig erscheint
        // und nicht sichtbar umschaltet.
        if let name = value(of: "--profile", in: arguments) {
            state.selectProfileForEditing(named: name)
        }
        if flags.contains("--general") {
            state.editingSelection = .general
        }
        if let tab = value(of: "--tab", in: arguments).flatMap(EditorTab.init(rawValue:)) {
            state.editorTab = tab
        }

        var opened = false
        if flags.contains("--settings") || flags.contains("--general")
            || flags.contains("--tab") || arguments.contains(where: { $0.hasPrefix("--tab=") })
        {
            openWindow(id: "settings")
            opened = true
        }
        if flags.contains("--status") {
            openWindow(id: "status")
            opened = true
        }
        // Ohne das bleibt das Fenster hinter allem anderen liegen, weil eine
        // LSUIElement-App beim Start nicht nach vorn kommt.
        if opened { NSApp.activate(ignoringOtherApps: true) }

        // Ein Prueflauf gleich nach dem Start. Nur damit die Statusansicht in
        // einem Bildschirmfoto etwas zeigt statt "noch nie geprueft".
        // Gefahrlos: Pruefen liest nur, es uebertraegt nichts und loescht nichts.
        //
        // Erst abwarten, bis die rsync-Suche durch ist. Die laeuft beim Start
        // als eigene Aufgabe, und wer davor prueft, faengt sich die Meldung
        // "Kein rsync gefunden" ein, die danach stehen bleibt.
        if flags.contains("--check") {
            Task {
                for _ in 0..<50 where state.rsyncInfo == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                await state.check()
            }
        }
    }

    /// Liest `--name=wert`. Nur diese Schreibweise, damit ein vergessener Wert
    /// nicht das naechste Argument verschluckt.
    private static func value(of name: String, in arguments: [String]) -> String? {
        let prefix = name + "="
        return arguments.first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }
}
