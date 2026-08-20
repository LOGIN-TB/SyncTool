import Foundation
import Testing

@testable import SyncCore

@Suite("rsync-Kommandozeile")
struct RsyncArgumentsTests {
    private func makeProfile(deleteAllowed: Bool = false, maxDelete: Int = 100) -> Profile {
        Profile(
            name: "Test",
            localRoot: "/Users/test/Develop",
            host: "u1.your-storagebox.de",
            port: 23,
            user: "u1",
            remotePath: "dev",
            deleteAllowed: deleteAllowed,
            maxDelete: maxDelete
        )
    }

    private func arguments(
        profile: Profile,
        direction: SyncDirection,
        dryRun: Bool,
        includeDeletes: Bool = false,
        protectFile: String? = nil
    ) -> [String] {
        RsyncArguments.arguments(
            profile: profile,
            direction: direction,
            options: .init(
                dryRun: dryRun,
                includeDeletes: includeDeletes,
                remoteShell: "/tmp/rsh",
                excludeFile: "/tmp/excludes",
                protectFile: protectFile
            )
        )
    }

    @Test("Trockenlauf ist markiert und lässt Übertragungsflags weg")
    func dryRunIsMarked() {
        let args = arguments(profile: makeProfile(), direction: .pull, dryRun: true)
        #expect(args.contains("--dry-run"))
        #expect(!args.contains("--partial"))
        #expect(!args.contains("--stats"))
    }

    @Test("Echter Lauf kann fortsetzen und liefert eine Bilanz")
    func realRunResumesAndReportsStats() {
        let args = arguments(profile: makeProfile(), direction: .push, dryRun: false)
        #expect(!args.contains("--dry-run"))
        #expect(args.contains("--partial"))
        #expect(args.contains("--partial-dir=.synctool-partial"))
        #expect(args.contains("--stats"))
    }

    @Test("Die Richtung bestimmt Quelle und Ziel")
    func directionDecidesSourceAndDestination() {
        let profile = makeProfile()
        #expect(
            Array(arguments(profile: profile, direction: .pull, dryRun: true).suffix(2))
                == ["u1@u1.your-storagebox.de:dev/", "/Users/test/Develop/"]
        )
        #expect(
            Array(arguments(profile: profile, direction: .push, dryRun: true).suffix(2))
                == ["/Users/test/Develop/", "u1@u1.your-storagebox.de:dev/"]
        )
    }

    @Test("Löschen braucht Erlaubnis im Profil und eine ausdrückliche Anforderung")
    func deleteNeedsBothPermissionAndRequest() {
        let forbidden = makeProfile(deleteAllowed: false)
        #expect(
            !arguments(profile: forbidden, direction: .push, dryRun: false, includeDeletes: true)
                .contains("--delete")
        )

        let allowed = makeProfile(deleteAllowed: true)
        #expect(
            !arguments(profile: allowed, direction: .push, dryRun: false, includeDeletes: false)
                .contains("--delete")
        )
        #expect(
            arguments(profile: allowed, direction: .push, dryRun: false, includeDeletes: true)
                .contains("--delete")
        )
    }

    @Test("Schutzregeln laufen nur mit, wenn auch gelöscht wird")
    func protectFileOnlyWithDelete() throws {
        let allowed = makeProfile(deleteAllowed: true)
        let withDelete = arguments(
            profile: allowed, direction: .push, dryRun: false,
            includeDeletes: true, protectFile: "/tmp/protect"
        )
        #expect(withDelete.contains("--filter=merge /tmp/protect"))
        // Erste passende Regel gewinnt, deshalb vor den Ausschluessen.
        let filterIndex = try #require(withDelete.firstIndex(of: "--filter=merge /tmp/protect"))
        let excludeIndex = try #require(withDelete.firstIndex(of: "--exclude-from=/tmp/excludes"))
        #expect(filterIndex < excludeIndex)

        #expect(
            !arguments(
                profile: allowed, direction: .push, dryRun: false,
                includeDeletes: false, protectFile: "/tmp/protect"
            ).contains("--filter=merge /tmp/protect")
        )
        #expect(
            !arguments(
                profile: makeProfile(deleteAllowed: false), direction: .push, dryRun: false,
                includeDeletes: true, protectFile: "/tmp/protect"
            ).contains("--filter=merge /tmp/protect")
        )
    }

    @Test("Sonderzeichen im Pfad werden für rsync entschärft")
    func protectRulesEscapeWildcards() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("synctool-protect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = try #require(
            try RsyncArguments.writeProtectFile(["ordner/stern*name[1].txt"], in: directory)
        )
        #expect(
            try String(contentsOfFile: file, encoding: .utf8)
                == "P /ordner/stern\\*name\\[1].txt\n"
        )
        #expect(try RsyncArguments.writeProtectFile([], in: directory) == nil)
    }

    @Test("Ein Lauf mit Löschen bekommt immer die Notbremse mit")
    func deleteRunsAlwaysCarryMaxDelete() {
        let profile = makeProfile(deleteAllowed: true, maxDelete: 42)
        #expect(
            arguments(profile: profile, direction: .push, dryRun: false, includeDeletes: true)
                .contains("--max-delete=42")
        )
    }

    @Test("Kein -a: Eigentümer und Gruppe bleiben außen vor")
    func archiveFlagDoesNotCarryOwnerAndGroup() {
        let args = arguments(profile: makeProfile(), direction: .push, dryRun: true)
        #expect(args.contains("-rlptz"))
        #expect(!args.contains("-a"))
        #expect(!args.contains("--archive"))
    }

    @Test("Prüfsummenvergleich nur auf Wunsch")
    func checksumOnlyWhenRequested() {
        var profile = makeProfile()
        #expect(!arguments(profile: profile, direction: .pull, dryRun: true).contains("--checksum"))
        profile.useChecksum = true
        #expect(arguments(profile: profile, direction: .pull, dryRun: true).contains("--checksum"))
    }

    @Test("Doppelte Schrägstriche am Pfadende werden geglättet")
    func trailingSlashesAreNormalised() {
        var profile = makeProfile()
        profile.localRoot = "/Users/test/Develop/"
        profile.remotePath = "dev/"
        #expect(profile.localSource == "/Users/test/Develop/")
        #expect(profile.remoteSource == "u1@u1.your-storagebox.de:dev/")
    }

    // MARK: - Bestandslauf

    private func inventoryArguments(
        side: RsyncArguments.InventorySide = .remote,
        excludeFile: String? = "/tmp/excludes",
        wantsChecksums: Bool = false
    ) -> [String] {
        RsyncArguments.inventoryArguments(
            profile: makeProfile(deleteAllowed: true, maxDelete: 42),
            options: .init(
                side: side, emptyDirectory: "/tmp/leer", remoteShell: "/tmp/rsh",
                excludeFile: excludeFile, wantsChecksums: wantsChecksums
            )
        )
    }

    /// Die wichtigste Schutzplanke: Ein Bestandslauf darf unter keinen
    /// Umstaenden etwas anfassen, auch nicht bei erlaubtem Loeschen.
    @Test("Ein Bestandslauf ist immer ein Trockenlauf und löscht nie")
    func inventoryRunNeverWrites() {
        let args = inventoryArguments()
        #expect(args.contains("--dry-run"))
        #expect(!args.contains("--delete"))
        #expect(!args.contains("--partial"))
        #expect(!args.contains("--stats"))
        #expect(!args.contains { $0.hasPrefix("--max-delete") })
        #expect(!args.contains { $0.hasPrefix("--filter") })
    }

    @Test("Das leere Zielverzeichnis steht am Ende, mit Schrägstrich")
    func inventoryRunTargetsTheEmptyDirectory() {
        #expect(Array(inventoryArguments().suffix(2)) == ["u1@u1.your-storagebox.de:dev/", "/tmp/leer/"])
        #expect(
            Array(inventoryArguments(side: .local).suffix(2))
                == ["/Users/test/Develop/", "/tmp/leer/"]
        )
    }

    /// Die lokale Seite laeuft ohne ssh, das ist die eingesparte Anmeldung.
    @Test("Nur die Fernseite bekommt eine Remote-Shell")
    func onlyTheRemoteSideNeedsSSH() {
        #expect(inventoryArguments(side: .remote).contains("-e"))
        #expect(!inventoryArguments(side: .local).contains("-e"))
    }

    @Test("Ausschlüsse greifen, außer beim Vergleichslauf")
    func inventoryRunHonoursExcludes() {
        #expect(inventoryArguments().contains("--exclude-from=/tmp/excludes"))
        #expect(
            !inventoryArguments(excludeFile: nil).contains { $0.hasPrefix("--exclude-from") }
        )
    }

    @Test("Prüfsummen bringen ein eigenes Ausgabeformat mit")
    func checksumInventoryUsesItsOwnFormat() {
        let plain = inventoryArguments()
        #expect(plain.contains("--out-format=\(ItemizeParser.inventoryFormat)"))
        #expect(!plain.contains("--checksum"))

        let hashed = inventoryArguments(wantsChecksums: true)
        #expect(hashed.contains("--out-format=\(ItemizeParser.inventoryChecksumFormat)"))
        #expect(hashed.contains("--checksum"))
    }

    /// Es wird nichts uebertragen, komprimiert wuerde nur die Luft.
    @Test("Der Bestandslauf komprimiert nicht")
    func inventoryRunDoesNotCompress() {
        #expect(inventoryArguments().contains("-rlpt"))
        #expect(!inventoryArguments().contains("-rlptz"))
    }

    @Test("Leere Ausschlussliste erzeugt keine Datei")
    func excludeFileSkippedWhenListIsEmpty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try RsyncArguments.writeExcludeFile([], in: directory) == nil)
        #expect(try RsyncArguments.writeExcludeFile(["  ", ""], in: directory) == nil)

        let written = try RsyncArguments.writeExcludeFile(
            ["node_modules/", " .DS_Store "], in: directory
        )
        let path = try #require(written)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "node_modules/\n.DS_Store\n")
    }
}

@Suite("ssh-Optionen")
struct SSHCommandTests {
    private let profile = Profile(localRoot: "/tmp", host: "example.org", port: 23, user: "u1")
    private let knownHosts = URL(fileURLWithPath: "/tmp/known_hosts")
    private let identity = URL(fileURLWithPath: "/tmp/id")

    @Test("Passwortmodus schaltet Key-Auth ab und begrenzt die Versuche")
    func passwordModeBlocksPubkey() {
        let options = SSHCommand.options(for: profile, knownHosts: knownHosts, identity: identity)
        #expect(options.contains("PubkeyAuthentication=no"))
        #expect(options.contains("NumberOfPasswordPrompts=1"))
        #expect(options.contains("StrictHostKeyChecking=yes"))
        #expect(options.contains("UserKnownHostsFile=/tmp/known_hosts"))
    }

    /// ssh liest den Wert als Liste von Dateien, getrennt durch Leerzeichen.
    /// Ohne Anführungszeichen sucht es in "/Users/x/Library/Application" und
    /// "Support/SyncTool/known_hosts" und findet nie einen Host-Key.
    @Test("Ein Pfad mit Leerzeichen bleibt für ssh eine einzige Datei")
    func knownHostsPathWithSpacesStaysOneFile() {
        let path = "/Users/x/Library/Application Support/SyncTool/known_hosts"
        let options = SSHCommand.options(
            for: profile, knownHosts: URL(fileURLWithPath: path), identity: identity
        )
        #expect(options.contains("UserKnownHostsFile=\"\(path)\""))
    }

    @Test("Ohne Leerzeichen bleibt der Wert unverändert")
    func optionValueLeavesPlainPathsAlone() {
        #expect(SSHCommand.optionValue("/tmp/known_hosts") == "/tmp/known_hosts")
        #expect(SSHCommand.optionValue("/a b/c") == "\"/a b/c\"")
    }

    @Test("Key-Modus läuft ohne Rückfragen")
    func keyModeRunsWithoutPrompts() {
        var keyProfile = profile
        keyProfile.authMode = .publicKey
        let options = SSHCommand.options(
            for: keyProfile, knownHosts: knownHosts, identity: identity
        )
        #expect(options.contains("BatchMode=yes"))
        #expect(options.contains("IdentitiesOnly=yes"))
        #expect(options.last == "/tmp/id")
    }

    @Test("Askpass wird nur erzwungen, wenn es einen Socket gibt")
    func environmentOnlyForcesAskpassWithSocket() {
        let askpass = URL(fileURLWithPath: "/opt/SyncToolAskpass")

        let withSocket = SSHCommand.environment(askpass: askpass, passwordSocket: "/tmp/s")
        #expect(withSocket["SSH_ASKPASS"] == "/opt/SyncToolAskpass")
        #expect(withSocket["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(withSocket["SYNCTOOL_PW_SOCK"] == "/tmp/s")

        let withoutSocket = SSHCommand.environment(askpass: askpass, passwordSocket: nil)
        #expect(withoutSocket["SSH_ASKPASS"] == nil)
        #expect(withoutSocket["SYNCTOOL_PW_SOCK"] == nil)
    }

    /// rsync zerlegt den `-e`-String an Leerzeichen und kennt keine
    /// Anfuehrungszeichen, "Application Support" braucht deshalb ein Skript.
    @Test("Das Remote-Shell-Skript quotet Pfade mit Leerzeichen")
    func remoteShellScriptQuotesPathsWithSpaces() {
        let script = SSHCommand.remoteShellScript(options: [
            "-o", "UserKnownHostsFile=/Users/x/Library/Application Support/SyncTool/known_hosts",
        ])
        #expect(script.hasPrefix("#!/bin/sh\n"))
        #expect(
            script.contains(
                "'UserKnownHostsFile=/Users/x/Library/Application Support/SyncTool/known_hosts'")
        )
        #expect(script.hasSuffix("\"$@\"\n"))
    }

    @Test("Einfache Anführungszeichen im Wert brechen das Quoting nicht auf")
    func quotingSurvivesApostrophes() {
        #expect(SSHCommand.shellQuote("a'b") == "'a'\\''b'")
    }
}
