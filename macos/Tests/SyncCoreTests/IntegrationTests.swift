import Foundation
import Testing

@testable import SyncCore

/// Findet die Produkte des laufenden Builds. Die Tests liegen im
/// .xctest-Bundle, die Binaries eine Ebene darueber.
private enum BuildProducts {
    static var directory: URL? {
        var url = Bundle.module.bundleURL
        for _ in 0..<6 {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent("SyncToolAskpass")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return url }
        }
        return nil
    }

    static var askpass: URL? {
        directory?.appendingPathComponent("SyncToolAskpass")
    }
}

@Suite("Askpass über den Passwort-Socket")
struct AskpassIntegrationTests {
    /// Der Weg, auf dem das Passwort tatsaechlich zu ssh gelangt. Faellt er
    /// aus, haengt jeder Lauf an der Passwortabfrage.
    @Test("Der Helfer holt das Passwort und gibt es auf stdout aus")
    func askpassReadsFromSocket() async throws {
        let askpass = try #require(BuildProducts.askpass, "SyncToolAskpass nicht gebaut")

        let socket = try PasswordSocket(password: "geheim-123")
        try socket.start()
        defer { socket.stop() }

        var environment = ProcessInfo.processInfo.environment
        environment["SYNCTOOL_PW_SOCK"] = socket.path

        let result = try await CommandRunner.run(
            executable: askpass.path,
            arguments: ["Password:"],
            environment: environment,
            timeout: 15
        )
        #expect(result.succeeded)
        #expect(result.standardOutput == "geheim-123\n")
    }

    @Test("Ohne Socket-Variable scheitert der Helfer, statt zu hängen")
    func askpassFailsWithoutSocket() async throws {
        let askpass = try #require(BuildProducts.askpass, "SyncToolAskpass nicht gebaut")

        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SYNCTOOL_PW_SOCK")

        let result = try await CommandRunner.run(
            executable: askpass.path,
            arguments: ["Password:"],
            environment: environment,
            timeout: 15
        )
        #expect(!result.succeeded)
        #expect(result.standardOutput.isEmpty)
    }

    /// Mit StrictHostKeyChecking=yes sollte diese Rueckfrage nie kommen. Falls
    /// doch, darf der Helfer nicht das Passwort als Bestaetigung ausgeben.
    @Test("Auf eine Host-Key-Rückfrage antwortet der Helfer nicht")
    func askpassRefusesHostKeyPrompts() async throws {
        let askpass = try #require(BuildProducts.askpass, "SyncToolAskpass nicht gebaut")

        let socket = try PasswordSocket(password: "geheim-123")
        try socket.start()
        defer { socket.stop() }

        var environment = ProcessInfo.processInfo.environment
        environment["SYNCTOOL_PW_SOCK"] = socket.path

        let result = try await CommandRunner.run(
            executable: askpass.path,
            arguments: [
                "The authenticity of host 'example.org' can't be established. "
                    + "Are you sure you want to continue connecting (yes/no)?"
            ],
            environment: environment,
            timeout: 15
        )
        #expect(!result.succeeded)
        #expect(!result.standardOutput.contains("geheim-123"))
    }

    @Test("Nach dem Stoppen bleibt kein Socket zurück")
    func socketIsCleanedUp() throws {
        let socket = try PasswordSocket(password: "x")
        try socket.start()
        let path = socket.path
        #expect(FileManager.default.fileExists(atPath: path))
        socket.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

@Suite("rsync mit echtem Binary")
struct RsyncIntegrationTests {
    private let rsync = "/usr/bin/rsync"

    /// Steht anstelle von ssh. rsync ruft "rsh <host> rsync --server …" auf,
    /// der Wrapper wirft den Host weg und fuehrt den Rest lokal aus.
    private func makeSandbox() throws -> (source: URL, destination: URL, remoteShell: String) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("synctool-rsync-\(UUID().uuidString)")
        let source = base.appendingPathComponent("src")
        let destination = base.appendingPathComponent("dst")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("sub"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        try "inhalt".write(
            to: source.appendingPathComponent("datei.txt"), atomically: true, encoding: .utf8
        )
        try "zwei".write(
            to: source.appendingPathComponent("sub/zwei.txt"), atomically: true, encoding: .utf8
        )
        try "wird ausgeschlossen".write(
            to: source.appendingPathComponent("ignoriert.log"), atomically: true, encoding: .utf8
        )

        let shell = base.appendingPathComponent("rsh")
        try "#!/bin/sh\nshift\nexec \"$@\"\n".write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: shell.path
        )
        return (source, destination, shell.path)
    }

    private func plan(
        source: URL, destination: URL, remoteShell: String, dryRun: Bool,
        excludeFile: String? = nil, protectFile: String? = nil,
        includeDeletes: Bool = false, deleteAllowed: Bool = false,
        direction: SyncDirection = .push
    ) -> RsyncPlan {
        let profile = Profile(
            localRoot: source.path,
            host: "localhost",
            port: 22,
            user: "irrelevant",
            remotePath: destination.path,
            deleteAllowed: deleteAllowed
        )
        return RsyncPlan(
            executable: rsync,
            arguments: RsyncArguments.arguments(
                profile: profile,
                direction: direction,
                options: .init(
                    dryRun: dryRun,
                    includeDeletes: includeDeletes,
                    remoteShell: remoteShell,
                    excludeFile: excludeFile,
                    protectFile: protectFile
                )
            ),
            environment: ProcessInfo.processInfo.environment
        )
    }

    /// Ein echter Bestandslauf gegen ein leeres Verzeichnis.
    private func inventory(
        of root: URL, remoteShell: String? = nil, excludeFile: String? = nil,
        rsync: String? = nil
    ) async throws -> SideInventory {
        let empty = root.deletingLastPathComponent()
            .appendingPathComponent("empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let profile = Profile(
            localRoot: root.path, host: "localhost", port: 22,
            user: "irrelevant", remotePath: root.path
        )
        var entries: [InventoryEntry] = []
        _ = try await RsyncRunner().execute(
            RsyncPlan(
                executable: rsync ?? self.rsync,
                arguments: RsyncArguments.inventoryArguments(
                    profile: profile,
                    options: .init(
                        side: .local, emptyDirectory: empty.path,
                        remoteShell: remoteShell, excludeFile: excludeFile
                    )
                ),
                environment: ProcessInfo.processInfo.environment
            ),
            onLine: { line in
                if let entry = ItemizeParser.parseInventoryLine(line, withChecksum: false) {
                    entries.append(entry)
                }
            }
        )
        return InventoryBuilder.build(from: entries)
    }

    @Test("Der Trockenlauf meldet Dateien, überträgt aber nichts")
    func dryRunTransfersNothing() async throws {
        let sandbox = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox.source.deletingLastPathComponent())
        }

        let outcome = try await RsyncRunner().execute(
            plan(
                source: sandbox.source, destination: sandbox.destination,
                remoteShell: sandbox.remoteShell, dryRun: true
            ),
            onLine: nil
        )

        #expect(outcome.succeeded)
        #expect(outcome.items.contains { $0.path == "datei.txt" && $0.kind == .created })
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: sandbox.destination.path).isEmpty
        )
    }

    @Test("Der echte Lauf überträgt und meldet dieselben Pfade")
    func realRunTransfers() async throws {
        let sandbox = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox.source.deletingLastPathComponent())
        }

        let outcome = try await RsyncRunner().execute(
            plan(
                source: sandbox.source, destination: sandbox.destination,
                remoteShell: sandbox.remoteShell, dryRun: false
            ),
            onLine: nil
        )

        #expect(outcome.succeeded)
        #expect(
            FileManager.default.fileExists(
                atPath: sandbox.destination.appendingPathComponent("sub/zwei.txt").path
            )
        )
        #expect(outcome.items.map(\.path).contains("sub/zwei.txt"))
    }

    @Test("Ein zweiter Lauf überträgt nichts mehr")
    func secondRunIsEmpty() async throws {
        let sandbox = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox.source.deletingLastPathComponent())
        }
        let runner = RsyncRunner()
        let transfer = plan(
            source: sandbox.source, destination: sandbox.destination,
            remoteShell: sandbox.remoteShell, dryRun: false
        )
        _ = try await runner.execute(transfer, onLine: nil)

        let second = try await runner.execute(
            plan(
                source: sandbox.source, destination: sandbox.destination,
                remoteShell: sandbox.remoteShell, dryRun: true
            ),
            onLine: nil
        )
        #expect(second.items.isEmpty)
    }

    /// Das gemeldete Szenario mit echtem rsync: alles abgeglichen, danach nur
    /// lokal gearbeitet. Eine Datei kommt dazu, eine andere faellt weg. Ohne
    /// Bestandsliste will die App die geloeschte Datei wieder herunterladen.
    @Test("Lokale Löschung landet beim Hochladen, nicht beim Herunterladen")
    func localDeletionIsNotAnIncomingDownload() async throws {
        let sandbox = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox.source.deletingLastPathComponent())
        }
        let runner = RsyncRunner()

        // Erst beide Seiten auf denselben Stand bringen.
        _ = try await runner.execute(
            plan(
                source: sandbox.source, destination: sandbox.destination,
                remoteShell: sandbox.remoteShell, dryRun: false
            ),
            onLine: nil
        )
        // Der gemeinsame Bestand nach dem Abgleich: die Schnittmenge beider Seiten.
        let common = try await inventory(of: sandbox.source).paths
            .intersection(try await inventory(of: sandbox.destination).paths)
        #expect(common.contains("datei.txt"))

        // Danach nur lokal arbeiten: eine loeschen, eine anlegen.
        try FileManager.default.removeItem(at: sandbox.source.appendingPathComponent("datei.txt"))
        try "frisch".write(
            to: sandbox.source.appendingPathComponent("frisch.txt"),
            atomically: true, encoding: .utf8
        )

        let status = DriftResolver.resolve(
            remote: try await inventory(of: sandbox.destination),
            local: try await inventory(of: sandbox.source),
            lastSync: Date(),
            knownPaths: common
        )
        #expect(status.incoming.isEmpty)
        #expect(status.deletionsOnPush.map(\.path) == ["datei.txt"])
        #expect(status.outgoing.map(\.path) == ["frisch.txt"])
        #expect(status.deletionsOnPull.isEmpty)
        #expect(status.protectedOnPush.isEmpty)
        #expect(status.protectedOnPull == ["frisch.txt"])
    }

    /// Genau die Frage aus dem Fehlerbericht: Der FTP-Client zeigt lokal mehr
    /// Dateien als auf dem Server. Die Differenz sind die Ausschluesse, und
    /// die muss die App benennen koennen.
    @Test("Die Ausschlussliste ist als Differenz zweier Läufe nachweisbar")
    func excludedPathsAreTheDifferenceBetweenTwoRuns() async throws {
        let sandbox = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox.source.deletingLastPathComponent())
        }
        let excludes = try #require(
            try RsyncArguments.writeExcludeFile(
                ["*.log"], in: sandbox.source.deletingLastPathComponent()
            )
        )

        let complete = try await inventory(of: sandbox.source)
        let filtered = try await inventory(of: sandbox.source, excludeFile: excludes)
        #expect(complete.paths.subtracting(filtered.paths) == ["ignoriert.log"])
    }

    /// Leere Ordner fielen vorher komplett aus der Auswertung: der Resolver
    /// warf jeden Verzeichniseintrag weg.
    @Test("Ein leerer Ordner steht im Bestand und wird als Abweichung gemeldet")
    func emptyDirectoriesAreCarried() async throws {
        let sandbox = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox.source.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(
            at: sandbox.source.appendingPathComponent("leer"), withIntermediateDirectories: true
        )

        let local = try await inventory(of: sandbox.source)
        #expect(local.entries["leer/"]?.type == .directory)

        let status = DriftResolver.resolve(
            remote: try await inventory(of: sandbox.destination),
            local: local,
            lastSync: nil
        )
        #expect(status.outgoing.map(\.path).contains("leer/"))
        // Der Ordner mit Inhalt wird von seinen Dateien mitgezogen.
        #expect(!status.outgoing.map(\.path).contains("sub/"))
    }

    /// Neun Flag-Zeichen bei openrsync, elf bei rsync 3. Der Bestand muss
    /// trotzdem derselbe sein, sonst haengt das Ergebnis am Binary.
    /// `.enabled(if:)` und nicht `#require`: ein fehlendes rsync 3.x ist kein
    /// Fehler dieses Projekts, sondern eine Eigenschaft des Rechners. `#require`
    /// liess den Test scheitern, statt ihn zu ueberspringen.
    @Test("Beide rsync-Varianten liefern denselben Bestand", .enabled(if: TestRsync.hasThree))
    func bothRsyncVariantsAgree() async throws {
        let homebrew = TestRsync.threePath
        let sandbox = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox.source.deletingLastPathComponent())
        }

        let open = try await inventory(of: sandbox.source)
        let three = try await inventory(of: sandbox.source, rsync: homebrew)
        #expect(open.paths == three.paths)
        #expect(open.entries["datei.txt"]?.size == three.entries["datei.txt"]?.size)
    }

    /// Der Ernstfall: Beim Hochladen mit --delete raeumt rsync alles weg, was
    /// die Quelle nicht hat, auch frisch auf dem Server entstandene Dateien.
    /// Die Schutzregeln muessen genau das verhindern.
    @Test("Geschützte Dateien überleben einen Lauf mit --delete")
    func protectedFilesSurviveDelete() async throws {
        let sandbox = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox.source.deletingLastPathComponent())
        }
        // Beides gibt es nur auf der Empfaengerseite.
        try "neu auf dem Server".write(
            to: sandbox.destination.appendingPathComponent("neu-dort.txt"),
            atomically: true, encoding: .utf8
        )
        try "lokal gelöscht".write(
            to: sandbox.destination.appendingPathComponent("lokal-geloescht.txt"),
            atomically: true, encoding: .utf8
        )

        let written = try RsyncArguments.writeProtectFile(
            ["neu-dort.txt"], in: sandbox.source.deletingLastPathComponent()
        )
        let protectFile = try #require(written)

        let outcome = try await RsyncRunner().execute(
            plan(
                source: sandbox.source, destination: sandbox.destination,
                remoteShell: sandbox.remoteShell, dryRun: false,
                protectFile: protectFile, includeDeletes: true, deleteAllowed: true
            ),
            onLine: nil
        )

        #expect(outcome.succeeded)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: sandbox.destination.appendingPathComponent("neu-dort.txt").path))
        #expect(
            !fm.fileExists(
                atPath: sandbox.destination.appendingPathComponent("lokal-geloescht.txt").path
            )
        )
        #expect(outcome.items.contains { $0.kind == .deleted && $0.path == "lokal-geloescht.txt" })
    }

    /// Der gemeldete Fall mit echtem rsync: derselbe Symlink auf beiden Seiten,
    /// nur die Rechte weichen ab. Kein Lauf bekommt das weg, also darf daraus
    /// kein Eintrag und schon gar kein Konflikt werden.
    @Test("Symlinks mit abweichenden Rechten tauchen nicht als Änderung auf")
    func symlinkPermissionNoiseIsNotAnItem() async throws {
        let sandbox = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox.source.deletingLastPathComponent())
        }

        for (side, mode) in [(sandbox.source, "700"), (sandbox.destination, "777")] {
            let link = side.appendingPathComponent("verweis.txt")
            try FileManager.default.createSymbolicLink(
                atPath: link.path, withDestinationPath: "datei.txt"
            )
            try chmod(mode, link)
        }
        // Der Inhalt selbst darf nicht dazwischenfunken.
        try "inhalt".write(
            to: sandbox.destination.appendingPathComponent("datei.txt"),
            atomically: true, encoding: .utf8
        )

        let outcome = try await RsyncRunner().execute(
            plan(
                source: sandbox.source, destination: sandbox.destination,
                remoteShell: sandbox.remoteShell, dryRun: true
            ),
            onLine: nil
        )

        #expect(!outcome.items.contains { $0.path == "verweis.txt" })
        #expect(outcome.skippedLinkAttributes == 1)

        // Und im Bestandsvergleich taucht der Laerm gar nicht erst auf: dort
        // entscheidet das Ziel des Verweises, nicht seine Rechte. Nur um den
        // Verweis geht es hier, der Rest der Sandbox ist absichtlich ungleich.
        let onlyLink = { (side: SideInventory) in
            SideInventory(entries: side.entries.filter { $0.key == "verweis.txt" })
        }
        let status = DriftResolver.resolve(
            remote: onlyLink(try await inventory(of: sandbox.destination)),
            local: onlyLink(try await inventory(of: sandbox.source)),
            lastSync: nil
        )
        #expect(status.conflicts.isEmpty)
        #expect(status.isInSync)
    }

    /// FileManager kennt keine Rechte fuer Symlinks, deshalb der Umweg.
    private func chmod(_ mode: String, _ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["-h", mode, url.path]
        try process.run()
        process.waitUntilExit()
    }

    @Test("--exclude-from greift")
    func excludesAreApplied() async throws {
        let sandbox = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox.source.deletingLastPathComponent())
        }
        let directory = sandbox.source.deletingLastPathComponent()
        let written = try RsyncArguments.writeExcludeFile(["*.log"], in: directory)
        let excludeFile = try #require(written)

        let outcome = try await RsyncRunner().execute(
            plan(
                source: sandbox.source, destination: sandbox.destination,
                remoteShell: sandbox.remoteShell, dryRun: false, excludeFile: excludeFile
            ),
            onLine: nil
        )

        #expect(outcome.succeeded)
        #expect(
            !FileManager.default.fileExists(
                atPath: sandbox.destination.appendingPathComponent("ignoriert.log").path
            )
        )
    }

    @Test("Jede Ausgabezeile erreicht den Aufrufer, während der Lauf läuft")
    func linesAreStreamed() async throws {
        let sandbox = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox.source.deletingLastPathComponent())
        }

        let collected = LineBox()
        _ = try await RsyncRunner().execute(
            plan(
                source: sandbox.source, destination: sandbox.destination,
                remoteShell: sandbox.remoteShell, dryRun: false
            ),
            onLine: { collected.append($0) }
        )
        #expect(collected.lines.contains { $0.contains("datei.txt") })
    }

    @Test("Ein abgebrochener Lauf meldet den Abbruch")
    func cancellationIsReported() async throws {
        let sandbox = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox.source.deletingLastPathComponent())
        }

        let runner = RsyncRunner()
        runner.cancel()

        await #expect(throws: RsyncError.self) {
            _ = try await runner.execute(
                self.plan(
                    source: sandbox.source, destination: sandbox.destination,
                    remoteShell: sandbox.remoteShell, dryRun: false
                ),
                onLine: nil
            )
        }
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: sandbox.destination.path).isEmpty
        )
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Ein lokales Ziel laeuft ohne ssh, ohne Passwort und ohne Askpass durch die
/// vollstaendige Maschine: pruefen, uebertragen, noch einmal pruefen.
///
/// Das Profil steht dabei absichtlich auf Passwortanmeldung ohne Passwort.
/// Genau daran waere ein solcher Lauf vorher gescheitert, weil `SyncEngine`
/// immer eine SSH-Sitzung aufbaute.
@Suite("Lokales Ziel von Ende zu Ende")
struct LocalFolderEngineTests {
    private struct Sandbox {
        let base: URL
        let source: URL
        let destination: URL
        let support: URL
        let profile: Profile
    }

    private func makeSandbox() throws -> Sandbox {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("synctool-lokal-\(UUID().uuidString)")
        let source = base.appendingPathComponent("quelle")
        let destination = base.appendingPathComponent("ziel")
        let support = base.appendingPathComponent("support")
        for url in [source.appendingPathComponent("unter"), destination, support] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try "eins".write(
            to: source.appendingPathComponent("eins.txt"), atomically: true, encoding: .utf8
        )
        try "zwei".write(
            to: source.appendingPathComponent("unter/zwei.txt"), atomically: true, encoding: .utf8
        )

        return Sandbox(
            base: base, source: source, destination: destination, support: support,
            profile: Profile(
                localRoot: source.path,
                remotePath: destination.path,
                // Bewusst Passwortanmeldung, bewusst ohne Passwort.
                authMode: .password,
                excludes: [],
                transport: .localFolder
            )
        )
    }

    private func engine(_ sandbox: Sandbox) -> SyncEngine {
        SyncEngine(
            runner: RsyncRunner(),
            stateStore: SyncStateStore(url: sandbox.support.appendingPathComponent("state.json")),
            inventoryStore: InventoryStore(directory: sandbox.support),
            knownHosts: sandbox.support.appendingPathComponent("known_hosts"),
            identity: sandbox.support.appendingPathComponent("id_ed25519"),
            // Eigener Ort statt des gemeinsamen Temp-Ordners, sonst zaehlt
            // dieser Test die Arbeitsordner parallel laufender Tests mit.
            workspaceParent: sandbox.base
        )
    }

    @Test("Prüfen, hochladen und noch einmal prüfen läuft ohne ssh durch")
    func fullRoundTripWithoutSSH() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }
        let engine = engine(sandbox)

        var log: [String] = []
        let status = try await engine.check(
            profile: sandbox.profile, password: nil, rsyncPath: "/usr/bin/rsync",
            onLog: { log.append($0) }
        )
        #expect(Set(status.outgoing.map(\.path)) == ["eins.txt", "unter/zwei.txt"])
        #expect(status.incoming.isEmpty)
        // Kein `-e` in der Kommandozeile, die ins Protokoll geschrieben wurde.
        #expect(!log.contains { $0.contains(" -e ") })

        _ = try await engine.transfer(
            profile: sandbox.profile, password: nil, direction: .push,
            includeDeletes: false, expectedItems: 2,
            remotePaths: status.remotePaths, localPaths: status.localPaths,
            rsyncPath: "/usr/bin/rsync"
        )
        let landed = sandbox.destination.appendingPathComponent("unter/zwei.txt")
        #expect(try String(contentsOf: landed, encoding: .utf8) == "zwei")

        let after = try await engine.check(
            profile: sandbox.profile, password: nil, rsyncPath: "/usr/bin/rsync"
        )
        #expect(after.isInSync)
    }

    @Test("Herunterladen holt aus dem Zielordner zurück")
    func pullFromTheFolder() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }
        try "nur dort".write(
            to: sandbox.destination.appendingPathComponent("drei.txt"),
            atomically: true, encoding: .utf8
        )
        let engine = engine(sandbox)

        let status = try await engine.check(
            profile: sandbox.profile, password: nil, rsyncPath: "/usr/bin/rsync"
        )
        #expect(status.incoming.map(\.path) == ["drei.txt"])

        _ = try await engine.transfer(
            profile: sandbox.profile, password: nil, direction: .pull,
            includeDeletes: false, expectedItems: 1,
            remotePaths: status.remotePaths, localPaths: status.localPaths,
            rsyncPath: "/usr/bin/rsync"
        )
        #expect(
            FileManager.default.fileExists(
                atPath: sandbox.source.appendingPathComponent("drei.txt").path
            )
        )
    }

    /// Der gefaehrliche Fall: der Zielordner liegt auf einem Laufwerk, das
    /// gerade nicht verbunden ist. Ohne diese Pruefung legte rsync ihn beim
    /// Hochladen einfach auf der Startplatte an.
    @Test("Ein fehlender Zielordner bricht den Lauf ab, statt ihn anzulegen")
    func missingTargetFolderStopsTheRun() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }
        var profile = sandbox.profile
        profile.remotePath = sandbox.base.appendingPathComponent("nicht-verbunden").path

        await #expect(throws: SyncEngineError.self) {
            _ = try await self.engine(sandbox).check(
                profile: profile, password: nil, rsyncPath: "/usr/bin/rsync"
            )
        }
        #expect(!FileManager.default.fileExists(atPath: profile.remotePath))
    }

    /// Der Arbeitsordner mit Ausschluss- und Schutzdatei haengt bei ssh am
    /// Sitzungsordner. Ohne Sitzung legt die Maschine einen eigenen an, und der
    /// muss danach wieder weg sein.
    @Test("Der Arbeitsordner bleibt nach dem Lauf nicht liegen")
    func workspaceIsCleanedUp() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }
        var profile = sandbox.profile
        profile.excludes = ["*.log"]

        _ = try await engine(sandbox).check(
            profile: profile, password: nil, rsyncPath: "/usr/bin/rsync"
        )
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sandbox.base.path)
            .filter { $0.hasPrefix("synctool-lauf-") }
        #expect(leftovers.isEmpty)
    }
}

/// Die ganze Suite braucht ein rsync 3.x: der Bestandslauf des Backups setzt
/// `-8` fuer unmaskierte Namen, und openrsync kann das nicht.
/// Der Kern der Aenderung: ein Repo geht als Einheit hinueber, und der Lauf,
/// der dafuer innerhalb von `.git` loescht, raeumt ausserhalb nichts weg.
///
/// Beide rsync-Fassungen, weil genau hier die Filtersprache entscheidet:
/// openrsync ist Protokoll 29, Homebrew liefert rsync 3.x.
@Suite("Git-Repos von Ende zu Ende")
struct GitRepositoryEngineTests {
    private struct Sandbox {
        let base: URL
        let source: URL
        let destination: URL
        let support: URL
        let profile: Profile
    }

    private func makeSandbox() throws -> Sandbox {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("synctool-git-\(UUID().uuidString)")
        let source = base.appendingPathComponent("quelle")
        let destination = base.appendingPathComponent("ziel")
        let support = base.appendingPathComponent("support")
        for url in [source, destination, support] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return Sandbox(
            base: base, source: source, destination: destination, support: support,
            profile: Profile(
                localRoot: source.path,
                remotePath: destination.path,
                authMode: .password,
                excludes: [],
                // Ohne Pruefsummen entscheiden Groesse und Zeit, und ein Ref ist
                // immer gleich lang.
                useChecksum: true,
                transport: .localFolder
            )
        )
    }

    private func engine(_ sandbox: Sandbox) -> SyncEngine {
        SyncEngine(
            runner: RsyncRunner(),
            stateStore: SyncStateStore(url: sandbox.support.appendingPathComponent("state.json")),
            inventoryStore: InventoryStore(directory: sandbox.support),
            knownHosts: sandbox.support.appendingPathComponent("known_hosts"),
            identity: sandbox.support.appendingPathComponent("id_ed25519"),
            workspaceParent: sandbox.base
        )
    }

    /// Schreibt eine Datei mit einem festen Zeitstempel. Der Abgleich
    /// entscheidet nach Zeit, geratene Zeitstempel machen den Test wacklig.
    private func write(_ text: String, to url: URL, age: TimeInterval) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path
        )
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private static let rsyncs: [String] = {
        var found = [TestRsync.systemRsync]
        if let three = TestRsync.three { found.append(three) }
        return found
    }()

    @Test("Ein Repo geht als Ganzes hinüber, alte Refs überleben nicht", arguments: rsyncs)
    func repositoryTransfersAsAWhole(rsync: String) async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }
        let engine = engine(sandbox)
        let remote = sandbox.destination
        let local = sandbox.source

        // Die Gegenseite ist weiter: neuer Ref, neues Objekt.
        try write("neu\n", to: remote.appendingPathComponent("P/.git/refs/heads/main"), age: 0)
        try write("ref: x\n", to: remote.appendingPathComponent("P/.git/HEAD"), age: 0)
        try write("objekt", to: remote.appendingPathComponent("P/.git/objects/ab/cdef"), age: 0)
        try write("neu", to: remote.appendingPathComponent("P/quelle.swift"), age: 0)

        // Hier steht der alte Stand, dazu Reste, die verschwinden müssen.
        try write("alt\n", to: local.appendingPathComponent("P/.git/refs/heads/main"), age: 7200)
        try write("ref: x\n", to: local.appendingPathComponent("P/.git/HEAD"), age: 7200)
        try write("altref\n", to: local.appendingPathComponent("P/.git/refs/heads/alt"), age: 7200)
        try write("packed\n", to: local.appendingPathComponent("P/.git/packed-refs"), age: 7200)
        try write("log\n", to: local.appendingPathComponent("P/.git/logs/HEAD"), age: 7200)
        // Außerhalb von .git, nur hier: muss überleben.
        try write("meins", to: local.appendingPathComponent("P/nur-hier.txt"), age: 7200)
        try write("oben", to: local.appendingPathComponent("nur-hier-oben.txt"), age: 7200)

        // Es gab schon einen Abgleich. Ohne dieses Gedächtnis sähen der alte
        // Ref und die packed-refs wie neue Arbeit von hier aus, und das Repo
        // liefe zu Recht als "auseinander" durch.
        InventoryStore(directory: sandbox.support).record(
            for: sandbox.profile,
            commonPaths: [
                "P/", "P/.git/", "P/.git/refs/", "P/.git/refs/heads/",
                "P/.git/HEAD", "P/.git/refs/heads/main", "P/.git/refs/heads/alt",
                "P/.git/packed-refs", "P/.git/logs/", "P/.git/logs/HEAD",
                "P/quelle.swift",
            ]
        )

        let status = try await engine.check(
            profile: sandbox.profile, password: nil, rsyncPath: rsync,
            supportsChecksumField: rsync != TestRsync.systemRsync
        )
        #expect(status.gitUnits.map(\.root) == ["P/"])
        #expect(status.gitUnits.first?.state == .incoming)
        // Kein einziger .git-Pfad steht noch einzeln in den Listen.
        #expect(!status.incoming.contains { $0.path.contains(".git/") })

        _ = try await engine.transfer(
            profile: sandbox.profile, password: nil, direction: .pull,
            // Der Haken im Statusfenster bleibt aus: innerhalb von .git wird
            // trotzdem geräumt, außerhalb nicht.
            includeDeletes: false,
            expectedItems: status.itemCount(for: .pull),
            gitUnits: status.gitUnits,
            remotePaths: status.remotePaths, localPaths: status.localPaths,
            rsyncPath: rsync
        )

        #expect(try text(local.appendingPathComponent("P/.git/refs/heads/main")) == "neu\n")
        #expect(exists(local.appendingPathComponent("P/.git/objects/ab/cdef")))
        #expect(!exists(local.appendingPathComponent("P/.git/refs/heads/alt")))
        #expect(!exists(local.appendingPathComponent("P/.git/packed-refs")))
        #expect(!exists(local.appendingPathComponent("P/.git/logs/HEAD")))
        // Und das ist der Unterschied zu einem globalen --delete:
        #expect(exists(local.appendingPathComponent("P/nur-hier.txt")))
        #expect(exists(local.appendingPathComponent("nur-hier-oben.txt")))
    }

    @Test("Ein Repo, das auseinanderläuft, bleibt unberührt", arguments: rsyncs)
    func divergedRepositoryStaysUntouched(rsync: String) async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }
        let engine = engine(sandbox)
        let remote = sandbox.destination
        let local = sandbox.source

        // Beide Seiten haben seit dem letzten Abgleich in .git geschrieben.
        try write("drüben\n", to: remote.appendingPathComponent("P/.git/refs/heads/main"), age: 0)
        try write("drüben\n", to: remote.appendingPathComponent("P/.git/logs/HEAD"), age: 7200)
        try write("neu", to: remote.appendingPathComponent("P/quelle.swift"), age: 0)
        try write("hier\n", to: local.appendingPathComponent("P/.git/refs/heads/main"), age: 7200)
        try write("hier\n", to: local.appendingPathComponent("P/.git/logs/HEAD"), age: 0)
        try write("alt", to: local.appendingPathComponent("P/quelle.swift"), age: 7200)

        let status = try await engine.check(
            profile: sandbox.profile, password: nil, rsyncPath: rsync,
            supportsChecksumField: rsync != TestRsync.systemRsync
        )
        #expect(status.gitUnits.map(\.state) == [.conflict])

        _ = try await engine.transfer(
            profile: sandbox.profile, password: nil, direction: .pull,
            includeDeletes: false,
            expectedItems: status.itemCount(for: .pull),
            gitUnits: status.gitUnits,
            remotePaths: status.remotePaths, localPaths: status.localPaths,
            rsyncPath: rsync
        )

        // .git unverändert, die Arbeitskopie aber übertragen.
        #expect(try text(local.appendingPathComponent("P/.git/refs/heads/main")) == "hier\n")
        #expect(try text(local.appendingPathComponent("P/.git/logs/HEAD")) == "hier\n")
        #expect(try text(local.appendingPathComponent("P/quelle.swift")) == "neu")
    }

    @Test("Ein Repo, das es hier noch nicht gibt, wird angelegt", arguments: rsyncs)
    func newRepositoryIsCreated(rsync: String) async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }
        let engine = engine(sandbox)

        // Verschachtelt, damit die Elternzeilen der Filterdatei mitgeprüft sind.
        try write(
            "ref: x\n", to: sandbox.destination.appendingPathComponent("a/b/.git/HEAD"), age: 0
        )
        try write("q", to: sandbox.destination.appendingPathComponent("a/b/quelle.swift"), age: 0)

        let status = try await engine.check(
            profile: sandbox.profile, password: nil, rsyncPath: rsync,
            supportsChecksumField: rsync != TestRsync.systemRsync
        )
        #expect(status.gitUnits.map(\.root) == ["a/b/"])

        _ = try await engine.transfer(
            profile: sandbox.profile, password: nil, direction: .pull,
            includeDeletes: false,
            expectedItems: status.itemCount(for: .pull),
            gitUnits: status.gitUnits,
            remotePaths: status.remotePaths, localPaths: status.localPaths,
            rsyncPath: rsync
        )

        #expect(try text(sandbox.source.appendingPathComponent("a/b/.git/HEAD")) == "ref: x\n")
        #expect(exists(sandbox.source.appendingPathComponent("a/b/quelle.swift")))

        let after = try await engine.check(
            profile: sandbox.profile, password: nil, rsyncPath: rsync,
            supportsChecksumField: rsync != TestRsync.systemRsync
        )
        #expect(after.isInSync)
    }
}

/// Der gemeldete Fehler, nachgestellt mit echten Repos: auf Rechner A
/// committen und pushen, hochladen, auf Rechner B herunterladen. Danach darf
/// git dort nicht "behind" melden.
@Suite("Zwei Rechner, ein Repo", .enabled(if: GitBinary.available))
struct TwoMachinesGitTests {
    private struct Bench {
        let base: URL
        /// Steht fuer GitHub.
        let origin: URL
        let machineA: URL
        let machineB: URL
        let box: URL
        let backup: URL
        let supportA: URL
        let supportB: URL
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitBinary.path)
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_AUTHOR_NAME"] = "Test"
        environment["GIT_AUTHOR_EMAIL"] = "test@example.org"
        environment["GIT_COMMITTER_NAME"] = "Test"
        environment["GIT_COMMITTER_EMAIL"] = "test@example.org"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CommandError.launchFailed("git " + arguments.joined(separator: " "), "Status \(process.terminationStatus)")
        }
    }

    private func gitOutput(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitBinary.path)
        process.arguments = ["-C", directory.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        // Sonst schreibt `git status` den Index neu, und schon meldet der
        // naechste Pruflauf das Repo als "hier geaendert".
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func makeBench() throws -> Bench {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("synctool-zwei-\(UUID().uuidString)")
        let bench = Bench(
            base: base,
            origin: base.appendingPathComponent("github.git"),
            machineA: base.appendingPathComponent("a"),
            machineB: base.appendingPathComponent("b"),
            box: base.appendingPathComponent("box"),
            backup: base.appendingPathComponent("sicherungen"),
            supportA: base.appendingPathComponent("support-a"),
            supportB: base.appendingPathComponent("support-b")
        )
        for url in [
            bench.origin, bench.machineA, bench.machineB, bench.box, bench.backup,
            bench.supportA, bench.supportB,
        ] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try git(["init", "--bare", "--initial-branch=main", "."], in: bench.origin)
        try git(["clone", bench.origin.path, "Projekt"], in: bench.machineA)
        return bench
    }

    private func commit(_ text: String, in repository: URL, push: Bool = true) throws {
        try text.write(
            to: repository.appendingPathComponent("datei.txt"), atomically: true, encoding: .utf8
        )
        try git(["add", "."], in: repository)
        try git(["commit", "-m", text], in: repository)
        if push { try git(["push", "origin", "main"], in: repository) }
    }

    private func profile(root: URL, box: URL, backup: URL) -> Profile {
        Profile(
            localRoot: root.path,
            remotePath: box.path,
            authMode: .password,
            excludes: [],
            useChecksum: true,
            backupDestination: backup.path,
            transport: .localFolder
        )
    }

    private func engine(support: URL, base: URL) -> SyncEngine {
        SyncEngine(
            runner: RsyncRunner(),
            stateStore: SyncStateStore(url: support.appendingPathComponent("state.json")),
            inventoryStore: InventoryStore(directory: support),
            knownHosts: support.appendingPathComponent("known_hosts"),
            identity: support.appendingPathComponent("id_ed25519"),
            workspaceParent: base
        )
    }

    /// Setzt alle Zeitstempel im Pruefstand eine Stunde zurueck.
    ///
    /// Im Test passiert alles innerhalb einer Sekunde, und `--modify-window=1`
    /// hielte deshalb jede Datei fuer gleich alt: ein Commit direkt nach einem
    /// Abgleich saehe aus wie ein Konflikt. In Wirklichkeit liegen dazwischen
    /// Minuten. Das hier stellt genau das her.
    private func age(_ directory: URL, by seconds: TimeInterval = 3600) throws {
        let manager = FileManager.default
        guard
            let walker = manager.enumerator(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
            )
        else { return }
        for case let url as URL in walker {
            guard
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
            else { continue }
            try? manager.setAttributes(
                [.modificationDate: modified.addingTimeInterval(-seconds)],
                ofItemAtPath: url.path
            )
        }
    }

    /// Prueft und uebertraegt in einem Zug, so wie es das Statusfenster tut.
    @discardableResult
    private func sync(
        _ engine: SyncEngine, _ profile: Profile, _ direction: SyncDirection
    ) async throws -> SyncStatus {
        let status = try await engine.check(
            profile: profile, password: nil, rsyncPath: TestRsync.systemRsync,
            supportsChecksumField: false
        )
        guard !status.isInSync else { return status }
        _ = try await engine.transfer(
            profile: profile, password: nil, direction: direction,
            includeDeletes: false,
            expectedItems: status.itemCount(for: direction),
            gitUnits: status.gitUnits,
            remotePaths: status.remotePaths, localPaths: status.localPaths,
            rsyncPath: TestRsync.systemRsync
        )
        return status
    }

    @Test("Nach Commit, Push und Abgleich hängt der zweite Rechner nicht zurück")
    func theReportedBug() async throws {
        let bench = try makeBench()
        defer { try? FileManager.default.removeItem(at: bench.base) }
        let repositoryA = bench.machineA.appendingPathComponent("Projekt")
        let repositoryB = bench.machineB.appendingPathComponent("Projekt")

        let profileA = profile(root: bench.machineA, box: bench.box, backup: bench.backup)
        let profileB = profile(root: bench.machineB, box: bench.box, backup: bench.backup)
        let engineA = engine(support: bench.supportA, base: bench.base)
        let engineB = engine(support: bench.supportB, base: bench.base)

        // Erster Durchlauf: A legt das Repo auf der Box ab, B holt es.
        try commit("eins", in: repositoryA)
        try await sync(engineA, profileA, .push)
        try await sync(engineB, profileB, .pull)
        try age(bench.base)
        #expect(try gitOutput(["rev-parse", "HEAD"], in: repositoryB)
            == (try gitOutput(["rev-parse", "HEAD"], in: repositoryA)))

        // Der eigentliche Fall: A arbeitet weiter, committet, pusht, gleicht ab.
        try commit("zwei", in: repositoryA)
        try commit("drei", in: repositoryA)
        // Ein Repack, damit lose Objekte wegfallen und packed-refs entsteht.
        // Genau das hat der Abgleich bisher nicht nachgezogen.
        try git(["gc", "--prune=now"], in: repositoryA)
        try await sync(engineA, profileA, .push)
        try age(bench.base)

        let status = try await sync(engineB, profileB, .pull)
        #expect(status.gitUnits.map(\.state) == [.incoming])

        // Das ist die Zeile, die vorher "behind 2" gesagt hätte.
        #expect(try gitOutput(["status", "-sb"], in: repositoryB).contains("[behind") == false)
        #expect(try gitOutput(["rev-parse", "HEAD"], in: repositoryB)
            == (try gitOutput(["rev-parse", "HEAD"], in: repositoryA)))
        #expect(try gitOutput(["rev-parse", "refs/remotes/origin/main"], in: repositoryB)
            == (try gitOutput(["rev-parse", "refs/remotes/origin/main"], in: repositoryA)))
        // Und die Prüfung danach ist still.
        let after = try await engineB.check(
            profile: profileB, password: nil, rsyncPath: TestRsync.systemRsync,
            supportsChecksumField: false
        )
        #expect(after.isInSync)
    }

    @Test("Hängt ein Repo hinter der Gegenstelle, spult SyncTool es vor")
    func fastForwardFromTheRemote() async throws {
        let bench = try makeBench()
        defer { try? FileManager.default.removeItem(at: bench.base) }
        let repositoryA = bench.machineA.appendingPathComponent("Projekt")
        let repositoryB = bench.machineB.appendingPathComponent("Projekt")

        let profileA = profile(root: bench.machineA, box: bench.box, backup: bench.backup)
        let profileB = profile(root: bench.machineB, box: bench.box, backup: bench.backup)
        try commit("eins", in: repositoryA)
        try await sync(engine(support: bench.supportA, base: bench.base), profileA, .push)
        try await sync(engine(support: bench.supportB, base: bench.base), profileB, .pull)
        try age(bench.base)

        // A pusht, gleicht aber nicht ab. B kommt nur über die Gegenstelle an
        // den neuen Stand.
        try commit("zwei", in: repositoryA)
        #expect(try gitOutput(["status", "-sb"], in: repositoryB).contains("[behind") == false)

        let backupEngine = BackupEngine(runner: ProcessRunner())
        let sync = GitSync(
            runner: GitCommandRunner(gitPath: GitBinary.path),
            snapshot: { root in
                try await backupEngine.snapshotRepository(
                    root: root, profile: profileB, rsyncPath: TestRsync.systemRsync
                ).archive
            }
        )
        let localPaths = try await engine(support: bench.supportB, base: bench.base)
            .check(
                profile: profileB, password: nil, rsyncPath: TestRsync.systemRsync,
                supportsChecksumField: false
            ).localPaths

        let results = await sync.run(
            roots: GitRepositories.roots(in: localPaths), localRoot: bench.machineB.path
        )
        #expect(results.map(\.root) == ["Projekt/"])
        #expect(results[0].action == .fastForwarded(commits: 1))
        #expect(try gitOutput(["rev-parse", "HEAD"], in: repositoryB)
            == (try gitOutput(["rev-parse", "HEAD"], in: repositoryA)))

        // Vor dem Eingriff wurde gesichert, und zwar mit .git.
        let archive = try #require(results[0].archive)
        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect(archive.lastPathComponent.hasPrefix("Projekt-bak-"))
    }

    @Test("Eigene Commits auf beiden Seiten bleiben liegen, nichts geht verloren")
    func divergedRepositoryIsLeftAlone() async throws {
        let bench = try makeBench()
        defer { try? FileManager.default.removeItem(at: bench.base) }
        let repositoryA = bench.machineA.appendingPathComponent("Projekt")
        let repositoryB = bench.machineB.appendingPathComponent("Projekt")

        let profileA = profile(root: bench.machineA, box: bench.box, backup: bench.backup)
        let profileB = profile(root: bench.machineB, box: bench.box, backup: bench.backup)
        try commit("eins", in: repositoryA)
        try await sync(engine(support: bench.supportA, base: bench.base), profileA, .push)
        try await sync(engine(support: bench.supportB, base: bench.base), profileB, .pull)
        try age(bench.base)

        try commit("von A", in: repositoryA)
        try commit("von B", in: repositoryB, push: false)
        let headB = try gitOutput(["rev-parse", "HEAD"], in: repositoryB)

        let sync = GitSync(
            runner: GitCommandRunner(gitPath: GitBinary.path),
            snapshot: { _ in Issue.record("Es wurde gesichert, obwohl nichts geschehen durfte") 
                return URL(fileURLWithPath: "/dev/null")
            }
        )
        let results = await sync.run(roots: ["Projekt/"], localRoot: bench.machineB.path)
        #expect(results[0].action == .skipped(.diverged))
        #expect(try gitOutput(["rev-parse", "HEAD"], in: repositoryB) == headB)
    }
}

/// Ohne git auf dem Rechner gibt es nichts zu pruefen.
enum GitBinary {
    static let path: String = GitLocator.searchPaths
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
    static var available: Bool {
        GitLocator.searchPaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

@Suite("Backup mit echtem zip", .enabled(if: TestRsync.hasThree))
struct BackupIntegrationTests {
    private let openrsync = TestRsync.systemRsync
    private let homebrew = TestRsync.threePath

    private struct Sandbox {
        let base: URL
        let source: URL
        let destination: URL
        var profile: Profile {
            var profile = Profile(localRoot: source.path, host: "h", user: "u", remotePath: "d")
            profile.backupDestination = destination.path
            return profile
        }
    }

    private func makeSandbox() throws -> Sandbox {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("synctool-backup-\(UUID().uuidString)")
        let source = base.appendingPathComponent("Develop")
        let destination = base.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("unter"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("leer"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        try "inhalt".write(
            to: source.appendingPathComponent("datei.txt"), atomically: true, encoding: .utf8
        )
        try "zwei".write(
            to: source.appendingPathComponent("unter/zwei.txt"), atomically: true, encoding: .utf8
        )
        try Data().write(to: source.appendingPathComponent(".DS_Store"))
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("verweis.txt").path,
            withDestinationPath: "datei.txt"
        )
        return Sandbox(base: base, source: source, destination: destination)
    }

    /// Listet den Archivinhalt. `-Z1` gibt eine Zeile je Eintrag.
    private func entries(of archive: URL) async throws -> [String] {
        let result = try await CommandRunner.run(
            executable: "/usr/bin/unzip", arguments: ["-Z1", archive.path], timeout: 60
        )
        return result.standardOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .sorted()
    }

    @Test("Das Archiv enthält genau die Pfade des Bestandslaufs")
    func archiveMatchesTheInventory() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }

        let result = try await BackupEngine(runner: ProcessRunner()).run(
            profile: sandbox.profile, rsyncPath: homebrew
        )
        let inhalt = try await entries(of: result.archive)

        #expect(inhalt == ["datei.txt", "leer/", "unter/", "unter/zwei.txt", "verweis.txt"])
        #expect(result.entryCount == inhalt.count)
        #expect(result.archiveBytes > 0)
    }

    /// Verzeichnisse fielen frueher komplett aus der Auswertung, ein leerer
    /// Ordner haette es nie ins Archiv geschafft.
    @Test("Ein leerer Ordner steht als Eintrag im Archiv")
    func emptyDirectoryIsArchived() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }

        let result = try await BackupEngine(runner: ProcessRunner()).run(
            profile: sandbox.profile, rsyncPath: homebrew
        )
        #expect(try await entries(of: result.archive).contains("leer/"))
    }

    @Test("Ein Symlink bleibt im Archiv ein Symlink")
    func symlinkStaysASymlink() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }

        let result = try await BackupEngine(runner: ProcessRunner()).run(
            profile: sandbox.profile, rsyncPath: homebrew
        )
        let listing = try await CommandRunner.run(
            executable: "/usr/bin/unzip",
            arguments: ["-Z", result.archive.path, "verweis.txt"], timeout: 60
        )
        // Das führende "l" im Rechte-String.
        #expect(listing.standardOutput.hasPrefix("l"))
    }

    @Test("Systemdateien fehlen im Archiv")
    func systemFilesAreLeftOut() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }

        let result = try await BackupEngine(runner: ProcessRunner()).run(
            profile: sandbox.profile, rsyncPath: homebrew
        )
        #expect(!(try await entries(of: result.archive).contains(".DS_Store")))
    }

    /// openrsync maskiert hohe Zeichen ohne `-8`. Mit homebrew-rsync waere der
    /// Test wertlos, weil das ohnehin roh ausgibt.
    @Test("Ein Dateiname mit Umlaut landet unverfälscht im Archiv")
    func umlautsSurvive() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }
        try "x".write(
            to: sandbox.source.appendingPathComponent("Ümläut-Größe.txt"),
            atomically: true, encoding: .utf8
        )

        let result = try await BackupEngine(runner: ProcessRunner()).run(
            profile: sandbox.profile, rsyncPath: openrsync
        )
        #expect(result.missing.isEmpty)

        // Auspacken und den Namen bitgenau vergleichen.
        let zurueck = sandbox.base.appendingPathComponent("zurueck")
        try FileManager.default.createDirectory(at: zurueck, withIntermediateDirectories: true)
        _ = try await CommandRunner.run(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", result.archive.path, zurueck.path], timeout: 60
        )
        #expect(
            FileManager.default.fileExists(
                atPath: zurueck.appendingPathComponent("Ümläut-Größe.txt").path
            )
        )
    }

    @Test("Die Teildatei wird umbenannt und bleibt nicht liegen")
    func partialFileIsRenamed() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }

        let result = try await BackupEngine(runner: ProcessRunner()).run(
            profile: sandbox.profile, rsyncPath: homebrew
        )
        let liegengeblieben = try FileManager.default
            .contentsOfDirectory(atPath: sandbox.destination.path)
            .filter { $0.hasSuffix(".part") }

        #expect(liegengeblieben.isEmpty)
        #expect(result.archive.lastPathComponent.hasSuffix(".zip"))
        #expect(result.archive.lastPathComponent.contains("Develop-bak-"))
    }

    /// zip ersetzt ein vorhandenes Archiv nicht, es schreibt es fort. Ohne
    /// Ausweichnamen waere das Ergebnis eine Mischung aus zwei Staenden.
    @Test("Ein zweites Backup weicht aus, statt das erste fortzuschreiben")
    func secondBackupPicksANewName() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }
        let engine = BackupEngine(runner: ProcessRunner())

        let erst = try await engine.run(profile: sandbox.profile, rsyncPath: homebrew)
        let groesse = erst.archiveBytes

        try "neu".write(
            to: sandbox.source.appendingPathComponent("dazu.txt"), atomically: true, encoding: .utf8
        )
        let zweit = try await engine.run(profile: sandbox.profile, rsyncPath: homebrew)

        #expect(erst.archive != zweit.archive)
        #expect(zweit.entryCount == erst.entryCount + 1)
        // Das erste Archiv ist unangetastet.
        let jetzt =
            (try? erst.archive.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        #expect(jetzt == groesse)
    }

    @Test("Ein Zielordner im Quellordner wird abgelehnt, bevor gepackt wird")
    func destinationInsideSourceIsRefused() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }
        var profile = sandbox.profile
        profile.backupDestination = sandbox.source.appendingPathComponent("unter").path

        await #expect(throws: BackupTargetError.self) {
            _ = try await BackupEngine(runner: ProcessRunner()).run(
                profile: profile, rsyncPath: self.homebrew
            )
        }
    }

    /// Beim Abbruch stand frueher ein Schreib-Thread mitten in der stdin-Pipe;
    /// das EPIPE haette per SIGPIPE die ganze App beendet.
    ///
    /// Abgebrochen wird aus der Fortschrittsmeldung heraus, also nachweislich
    /// mitten im Packen und nicht davor oder danach.
    @Test("Ein abgebrochener Lauf hinterlässt weder Archiv noch Teildatei", .timeLimit(.minutes(2)))
    func cancelledRunLeavesNothingBehind() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }

        let viele = sandbox.source.appendingPathComponent("viele")
        try FileManager.default.createDirectory(at: viele, withIntermediateDirectories: true)
        for index in 0..<6_000 {
            FileManager.default.createFile(
                atPath: viele.appendingPathComponent("f\(index).txt").path,
                contents: Data("\(index)".utf8)
            )
        }

        let runner = ProcessRunner()
        let engine = BackupEngine(runner: runner)

        await #expect(throws: ProcessRunnerError.self) {
            _ = try await engine.run(
                profile: sandbox.profile, rsyncPath: self.homebrew,
                onProgress: { _ in runner.cancel() }
            )
        }

        let uebrig = try FileManager.default.contentsOfDirectory(atPath: sandbox.destination.path)
        #expect(uebrig.isEmpty, "Im Zielordner liegt noch: \(uebrig)")
    }

    /// Die eigentliche Frage: 10 MB Dateiliste durch eine Pipe zu schieben,
    /// waehrend zip auf stdout schreibt, verklemmt sich. Ueber eine Datei nicht.
    @Test("Eine Liste mit 20.000 Namen läuft ohne Verklemmung durch", .timeLimit(.minutes(2)))
    func largeListDoesNotDeadlock() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }

        let viele = sandbox.source.appendingPathComponent("viele")
        try FileManager.default.createDirectory(at: viele, withIntermediateDirectories: true)
        for index in 0..<20_000 {
            FileManager.default.createFile(
                atPath: viele.appendingPathComponent("f\(index).txt").path,
                contents: Data("\(index)".utf8)
            )
        }

        var gemeldet: [TransferProgress] = []
        let result = try await BackupEngine(runner: ProcessRunner()).run(
            profile: sandbox.profile, rsyncPath: homebrew,
            onProgress: { gemeldet.append($0) }
        )

        #expect(result.entryCount > 20_000)
        #expect(result.missing.isEmpty)
        #expect(try await entries(of: result.archive).count == result.entryCount)
        // Gedrosselt: nicht bei jedem der 20.000 Einträge eine Meldung.
        #expect(gemeldet.count < 2_000)
        #expect(gemeldet.last?.completed == result.entryCount)
    }
}
