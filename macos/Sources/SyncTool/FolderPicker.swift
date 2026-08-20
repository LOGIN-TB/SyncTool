import AppKit

/// Ordnerauswahl fuer Stammordner und Backup-Ziel.
///
/// Die beiden Aufrufe unterschieden sich nur in der Beschriftung, standen aber
/// als zwei fast gleiche Methoden nebeneinander.
enum FolderPicker {
    static func choose(message: String, startingAt current: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Wählen"
        panel.message = message
        if !current.isEmpty { panel.directoryURL = URL(fileURLWithPath: current) }
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }
}
