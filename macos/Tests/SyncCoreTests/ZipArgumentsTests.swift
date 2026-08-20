import Foundation
import Testing

@testable import SyncCore

@Suite("Zip-Kommandozeile und Ausgabe")
struct ZipArgumentsTests {
    private func entry(_ path: String, type: ItemType = .file, size: Int64 = 10) -> InventoryEntry {
        InventoryEntry(path: path, type: type, size: size, modified: Date())
    }

    private func inventory(_ entries: [InventoryEntry]) -> SideInventory {
        InventoryBuilder.build(from: entries)
    }

    /// `-X` wirft laut Handbuch "uid/gid and file times on Unix" weg. Uebrig
    /// bliebe der DOS-Zeitstempel mit zwei Sekunden Aufloesung ohne Zeitzone.
    @Test("Der Zip-Lauf verzichtet auf -X, sonst fehlen die Zeitstempel")
    func noDashXSoTimestampsSurvive() {
        let args = ZipArguments.arguments(archive: "/ziel/a.zip.part")
        #expect(!args.contains("-X"))
        #expect(!args.contains("-q"))
        #expect(!args.contains("-r"))
        #expect(!args.contains("-D"))
        #expect(!args.contains("-e"))
    }

    @Test("Symlinks bleiben Symlinks und die Liste kommt von der Standardeingabe")
    func symlinksAndListFromStdin() {
        let args = ZipArguments.arguments(archive: "/ziel/a.zip.part")
        #expect(args.contains("-y"))
        #expect(args.contains("-@"))
        #expect(args.last == "/ziel/a.zip.part")
        #expect(args.first == ZipArguments.compressionLevel)
    }

    /// zip kann Sockets und Geraetedateien nicht, die braechten nur Status 18.
    @Test("Sockets und Geräte stehen nicht in der Dateiliste")
    func specialFilesAreLeftOut() {
        let list = ZipArguments.fileList(
            from: inventory([
                entry("datei.txt"),
                entry("ordner/", type: .directory),
                entry("verweis", type: .symlink),
                entry("socket", type: .special),
                entry("geraet", type: .device),
            ])
        )
        #expect(list == ["datei.txt", "ordner/", "verweis"])
    }

    @Test("Der Wurzeleintrag steht nicht in der Dateiliste")
    func rootEntryIsLeftOut() {
        let list = ZipArguments.fileList(
            from: inventory([entry("./", type: .directory), entry("a.txt")])
        )
        #expect(list == ["a.txt"])
    }

    @Test("Die Dateiliste ist sortiert und damit reproduzierbar")
    func listIsSorted() {
        let list = ZipArguments.fileList(
            from: inventory([entry("z.txt"), entry("a.txt"), entry("m.txt")])
        )
        #expect(list == ["a.txt", "m.txt", "z.txt"])
    }

    @Test("Die Liste wird zeilenweise geschrieben")
    func listIsWrittenLineByLine() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("liste-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let count = try ZipArguments.writeFileList(["a.txt", "mit leerzeichen.txt", "b/"], to: url)
        #expect(count == 3)
        #expect(
            try String(contentsOf: url, encoding: .utf8) == "a.txt\nmit leerzeichen.txt\nb/\n"
        )
    }

    // MARK: - Ausschlüsse

    /// Zwei getrennte Listen: die eine ist eine Entscheidung des Nutzers ueber
    /// den Abgleich, die andere gehoert in kein Archiv.
    @Test("Systemdateien und Profilausschlüsse sind getrennte Listen")
    func systemExcludesAreSeparate() {
        #expect(Profile.systemExcludes.contains(".DS_Store"))
        #expect(!Profile.systemExcludes.contains("node_modules/"))
        #expect(Profile.defaultExcludes.contains("node_modules/"))
    }

    /// Sonst packt das Backup von morgen das Archiv von heute mit ein.
    @Test("Die eigenen Archive stehen in den Systemausschlüssen")
    func ownArchivesAreExcluded() {
        #expect(Profile.systemExcludes.contains("*.zip.part"))
        #expect(Profile.systemExcludes.contains("*-bak-????-??-??*.zip"))
    }

    /// openrsync schreibt Umlaute sonst als "\#303\#244", und zip fände die
    /// Datei nicht. Im Prüfpfad darf das nicht an, dort sind die gespeicherten
    /// Bestandslisten in der maskierten Schreibweise abgelegt.
    @Test("Der Backup-Bestandslauf lässt hohe Zeichen unescaped, der Prüflauf nicht")
    func onlyTheBackupRunAsksForRawNames() {
        let profile = Profile(localRoot: "/x", host: "h", user: "u")
        let backup = RsyncArguments.inventoryArguments(
            profile: profile,
            options: .init(side: .local, emptyDirectory: "/tmp/leer", wantsRawNames: true)
        )
        let check = RsyncArguments.inventoryArguments(
            profile: profile, options: .init(side: .local, emptyDirectory: "/tmp/leer")
        )
        #expect(backup.contains("-8"))
        #expect(!check.contains("-8"))
    }

    // MARK: - Ausgabe

    @Test("Aus einer adding-Zeile wird der Pfad ohne Kompressionsangabe")
    func addingLineYieldsThePath() {
        #expect(
            ZipOutputParser.classify("  adding: unter/datei.txt (deflated 62%)")
                == .added("unter/datei.txt")
        )
        #expect(ZipOutputParser.classify("  adding: leer/ (stored 0%)") == .added("leer/"))
    }

    /// Zerlegt man an der ersten Klammer, bleibt der halbe Name liegen.
    @Test("Ein Pfad mit Klammern im Namen bleibt vollständig")
    func bracketsInNamesSurvive() {
        #expect(
            ZipOutputParser.classify("  adding: Bild (1) (Kopie).png (deflated 3%)")
                == .added("Bild (1) (Kopie).png")
        )
    }

    @Test("Nicht gefundene Namen werden gezählt, nicht als Fehler gewertet")
    func missingNamesAreCounted() {
        #expect(
            ZipOutputParser.classify("\tzip warning: name not matched: weg.txt")
                == .notMatched("weg.txt")
        )
    }

    @Test("Alles andere wird übergangen")
    func everythingElseIsIgnored() {
        #expect(ZipOutputParser.classify("") == .other)
        #expect(ZipOutputParser.classify("total bytes=123, compressed=45") == .other)
    }
}
