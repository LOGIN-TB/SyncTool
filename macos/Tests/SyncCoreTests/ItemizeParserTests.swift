import Foundation
import Testing

@testable import SyncCore

@Suite("Itemize-Parser")
struct ItemizeParserTests {
    private func fixture(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "txt")
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func indexed(_ text: String) -> [String: ChangeItem] {
        Dictionary(ItemizeParser.parse(text).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - openrsync, neun Flag-Zeichen

    @Test("Erstlauf: neue Dateien, Symlink, Verzeichnis, Löschung")
    func openRsyncInitialRun() throws {
        let text = try fixture("openrsync-initial")
        let items = ItemizeParser.parse(text)
        #expect(items.count == 5)

        let byPath = indexed(text)
        #expect(byPath["veraltet.txt"]?.kind == .deleted)
        #expect(byPath["eins.txt"]?.kind == .created)
        #expect(byPath["eins.txt"]?.type == .file)
        #expect(byPath["eins.txt"]?.size == 6)
        #expect(byPath["link.txt"]?.type == .symlink)
        #expect(byPath["sub/"]?.type == .directory)
        #expect(byPath["sub/zwei.txt"]?.kind == .created)
    }

    @Test("Inhaltsänderung und reine Zeitstempeländerung bleiben getrennt")
    func openRsyncDistinguishesContentFromTimestamp() throws {
        let byPath = indexed(try fixture("openrsync-changed"))
        // ">f.s....." – Groesse abweichend, also echter Inhaltsunterschied.
        #expect(byPath["eins.txt"]?.kind == .updated)
        // ">f..t...." – nur der Zeitstempel.
        #expect(byPath["sub/zwei.txt"]?.kind == .metadataOnly)
    }

    @Test("%M wird als Datum gelesen")
    func parsesModificationTime() throws {
        let byPath = indexed(try fixture("openrsync-changed"))
        let modified = try #require(byPath["sub/zwei.txt"]?.modified)
        let components = Calendar.current.dateComponents([.year, .month, .day], from: modified)
        #expect(components.year == 2030)
        #expect(components.month == 1)
        #expect(components.day == 1)
    }

    // MARK: - rsync 3.x, elf Flag-Zeichen

    @Test("Elf Flag-Zeichen werden genauso erkannt")
    func rsync3Format() throws {
        let byPath = indexed(try fixture("rsync3-mixed"))
        #expect(byPath["neu.txt"]?.kind == .created)
        #expect(byPath["projekt/quelle.swift"]?.kind == .updated)
        #expect(byPath["projekt/nur-zeit.txt"]?.kind == .metadataOnly)
        #expect(byPath["verweis.txt"]?.type == .symlink)
        #expect(byPath["projekt/"]?.type == .directory)
    }

    @Test("rsync 3.x schickt Löschzeilen durch das Ausgabeformat")
    func rsync3DeletionGoesThroughOutputFormat() throws {
        let items = ItemizeParser.parse(try fixture("rsync3-mixed"))
        #expect(items.filter { $0.kind == .deleted }.map(\.path) == ["alt/entfernt.txt"])
    }

    @Test("Unveränderte Dateien fallen raus, Rechteänderungen bleiben als Metadatenfall")
    func unchangedLinesAreDropped() throws {
        let text = try fixture("rsync3-mixed")
        let items = ItemizeParser.parse(text)
        #expect(!items.contains { $0.path == "unveraendert.txt" })
        #expect(indexed(text)["rechte-geaendert.sh"]?.kind == .metadataOnly)
    }

    // MARK: - Symlinks

    /// Der Fall aus dem Fehlerbericht: vier Symlinks auf der Storage Box, die
    /// rsync nach jedem Lauf erneut mit abweichenden Rechten meldet.
    @Test("Symlinks mit reiner Rechteabweichung fallen raus und werden gezählt")
    func symlinkAttributeNoiseIsSkipped() throws {
        let result = ItemizeParser.parseCounting(try fixture("storagebox-symlinks"))
        #expect(result.items.isEmpty)
        #expect(result.skippedLinkAttributes == 4)

    }

    @Test("Angelegte und umgehängte Symlinks bleiben erhalten")
    func createdSymlinksSurvive() throws {
        let result = ItemizeParser.parseCounting(try fixture("rsync3-mixed"))
        #expect(result.items.contains { $0.path == "verweis.txt" && $0.type == .symlink })
        #expect(result.skippedLinkAttributes == 0)
    }

    @Test("Rechteabweichung an einer normalen Datei bleibt ein Metadatenfall")
    func fileAttributeChangeIsNotSkipped() {
        let item = ItemizeParser.parseLine(".f...p.....|64|2026/08/16-12:46:24|rechte.sh")
        #expect(item?.kind == .metadataOnly)
        #expect(item?.type == .file)
    }

    @Test("Ein Pipe-Zeichen im Dateinamen zerlegt den Pfad nicht")
    func pathContainingPipeSurvives() throws {
        let items = ItemizeParser.parse(try fixture("rsync3-mixed"))
        #expect(items.contains { $0.path == "seltsam|name.txt" })
    }

    @Test("Statuszeilen und Bruchstücke werden ignoriert")
    func garbageLinesAreIgnored() {
        #expect(ItemizeParser.parseLine("") == nil)
        #expect(ItemizeParser.parseLine("sending incremental file list") == nil)
        #expect(ItemizeParser.parseLine("total size is 1234  speedup is 1.00") == nil)
        #expect(ItemizeParser.parseLine(">f+++++++|6|2026/08/16-12:46:24|") == nil)
    }

    // MARK: - Bestandslauf

    /// Der Lauf gegen ein leeres Verzeichnis. Jeder Eintrag fehlt beim
    /// Empfaenger und wird deshalb aufgelistet, samt leerer Ordner.
    @Test("Ein Bestandslauf von rsync 3 liefert jeden Eintrag", arguments: [
        "inventory-rsync3", "inventory-openrsync",
    ])
    func inventoryListsEverything(_ name: String) throws {
        let inventory = ItemizeParser.parseInventory(try fixture(name), withChecksum: false)

        // Drei Dateien plus der Symlink; Ordner zaehlen getrennt.
        #expect(inventory.fileCount == 4)
        #expect(inventory.directoryCount == 2)
        #expect(inventory.entries["datei.txt"]?.size == 6)
        #expect(inventory.entries["unter/zwei.txt"]?.type == .file)
        // Ohne die faellt ein leerer Ordner unter den Tisch.
        #expect(inventory.entries["leer/"]?.type == .directory)
        // Die Ausschlussliste des Laufs hat sie herausgehalten.
        #expect(inventory.entries["ignoriert.log"] == nil)
    }

    /// Der Pfad steht zwischen den festen Feldern vorn und dem Symlink-Ziel
    /// hinten. Nur deshalb bleibt ein "|" darin unversehrt.
    @Test("Ein Pipe-Zeichen im Pfad übersteht den Bestandslauf", arguments: [
        "inventory-rsync3", "inventory-openrsync",
    ])
    func inventoryKeepsPipesInPaths(_ name: String) throws {
        let inventory = ItemizeParser.parseInventory(try fixture(name), withChecksum: false)
        #expect(inventory.entries["mit|pipe.txt"]?.size == 4)
    }

    @Test("Das Symlink-Ziel kommt als eigenes Feld mit", arguments: [
        "inventory-rsync3", "inventory-openrsync",
    ])
    func inventoryCarriesTheLinkTarget(_ name: String) throws {
        let inventory = ItemizeParser.parseInventory(try fixture(name), withChecksum: false)
        let link = try #require(inventory.entries["verweis.txt"])
        #expect(link.type == .symlink)
        #expect(link.linkTarget == "datei.txt")
    }

    @Test("Mit --checksum stehen die Prüfsummen der Dateien in der Liste")
    func inventoryCarriesChecksums() throws {
        let inventory = ItemizeParser.parseInventory(
            try fixture("inventory-rsync3-checksum"), withChecksum: true
        )
        #expect(inventory.entries["datei.txt"]?.checksum == "029768816c221f78b5b2ebb885f75748")
        #expect(inventory.entries["mit|pipe.txt"]?.checksum == "387f1c823014e1e3cb076014b89996f1")
        // Ordner und Symlinks bekommen von rsync nur Leerzeichen.
        #expect(inventory.entries["leer/"]?.checksum == nil)
        #expect(inventory.entries["verweis.txt"]?.checksum == nil)
    }

    /// rsync meldet den Stammordner selbst. Der steht fuer kein Element darin.
    @Test("Der Wurzeleintrag fällt raus")
    func rootEntryIsDropped() {
        let inventory = ItemizeParser.parseInventory(
            ".d..t......|192|2026/08/16-12:48:42|./|\n"
                + ">f+++++++++|6|2026/08/16-12:48:42|a.txt|",
            withChecksum: false
        )
        #expect(inventory.paths == ["a.txt"])
    }

    @Test("Ein Ordner weiß, ob unter ihm noch etwas liegt")
    func directoriesKnowTheirChildren() throws {
        let inventory = ItemizeParser.parseInventory(
            try fixture("inventory-rsync3"), withChecksum: false
        )
        #expect(inventory.hasChildren(of: "unter/"))
        #expect(!inventory.hasChildren(of: "leer/"))
    }
}
