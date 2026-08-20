import Foundation

public struct BackupResult: Sendable {
    public let archive: URL
    public let entryCount: Int
    /// Ungepackte Groesse aller Eintraege.
    public let rawBytes: Int64
    public let archiveBytes: Int64
    public let duration: TimeInterval
    /// Namen, die zip nicht gefunden oder nicht gelesen hat. Leer ist der
    /// Normalfall; was hier steht, fehlt im Archiv und muss gemeldet werden.
    public let missing: [String]

    public init(
        archive: URL, entryCount: Int, rawBytes: Int64, archiveBytes: Int64,
        duration: TimeInterval, missing: [String]
    ) {
        self.archive = archive
        self.entryCount = entryCount
        self.rawBytes = rawBytes
        self.archiveBytes = archiveBytes
        self.duration = duration
        self.missing = missing
    }
}

public enum BackupError: LocalizedError {
    case nothingToArchive
    case noFreeName(String)
    case zipMissing(String)
    case zipFailed(status: Int32, detail: String)

    public var errorDescription: String? {
        switch self {
        case .nothingToArchive:
            return "Im Stammordner ist nichts zu sichern."
        case .noFreeName(let directory):
            return "In \(directory) ist kein freier Dateiname mehr frei. "
                + "Dort liegen bereits sehr viele Backups von heute."
        case .zipMissing(let path):
            return "\(path) wurde nicht gefunden."
        case .zipFailed(let status, let detail):
            return "Das Packen endete mit Status \(status): \(detail)"
        }
    }
}

/// Packt den lokalen Stammordner in ein Zip-Archiv.
///
/// Rein lokal: keine SSH-Sitzung, kein Passwort, keine Anmeldung. Die Liste der
/// Pfade kommt aus demselben Bestandslauf, den auch der Abgleich benutzt, damit
/// die rsync-Filtersprache, leere Ordner und Symlinks nicht nachgebaut werden.
public final class BackupEngine {
    private let runner: ProcessRunner
    private let zipPath: String

    public init(runner: ProcessRunner, zipPath: String = ZipArguments.executable) {
        self.runner = runner
        self.zipPath = zipPath
    }

    /// Fortschritt nicht bei jedem Eintrag melden.
    ///
    /// Bei 265.811 Eintraegen wuerde das UI 265.811 Aufgaben auf den Hauptthread
    /// schieben und stehen bleiben.
    private static let progressStride = 100
    private static let progressInterval: TimeInterval = 0.1

    public func run(
        profile: Profile,
        rsyncPath: String,
        ignoreSpace: Bool = false,
        at date: Date = Date(),
        onLog: ((String) -> Void)? = nil,
        onProgress: ((TransferProgress) -> Void)? = nil
    ) async throws -> BackupResult {
        let started = Date()
        guard FileManager.default.isExecutableFile(atPath: zipPath) else {
            throw BackupError.zipMissing(zipPath)
        }
        let problems = profile.validationErrors().filter { $0.hasPrefix("Lokaler Ordner") }
        guard problems.isEmpty else { throw SyncEngineError.invalidProfile(problems) }

        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        onLog?("Bestand aufnehmen …")
        let inventory = try await takeInventory(
            profile: profile, rsyncPath: rsyncPath, in: workspace, onLog: onLog
        )
        let paths = ZipArguments.fileList(from: inventory)
        guard !paths.isEmpty else { throw BackupError.nothingToArchive }
        onLog?("\(paths.count) Einträge, \(inventory.totalBytes) Bytes ungepackt.")

        try BackupTarget.validate(
            destination: profile.backupDestination,
            source: profile.localRoot,
            requiredBytes: inventory.totalBytes,
            ignoreSpace: ignoreSpace
        )

        let directory = URL(fileURLWithPath: profile.backupDestination, isDirectory: true)
        guard
            let archive = BackupName.nextFree(
                root: profile.localRoot, date: date, in: directory,
                exists: { FileManager.default.fileExists(atPath: $0.path) }
            )
        else { throw BackupError.noFreeName(profile.backupDestination) }

        let partial = BackupName.partial(for: archive)
        // zip ersetzt eine vorhandene Datei nicht, es liest sie ein und schreibt
        // sie fort. Eine liegengebliebene Teildatei wuerde sonst still zur
        // Mischung aus zwei Staenden.
        try? FileManager.default.removeItem(at: partial)

        let listURL = workspace.appendingPathComponent("list.txt")
        try ZipArguments.writeFileList(paths, to: listURL)

        let missing = try await pack(
            profile: profile, partial: partial, listURL: listURL,
            total: paths.count, onLog: onLog, onProgress: onProgress
        )

        try FileManager.default.moveItem(at: partial, to: archive)
        let archiveBytes =
            (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0

        return BackupResult(
            archive: archive,
            entryCount: paths.count,
            rawBytes: inventory.totalBytes,
            archiveBytes: archiveBytes,
            duration: Date().timeIntervalSince(started),
            missing: missing
        )
    }

    // MARK: - Intern

    private func makeWorkspace() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("synctool-backup-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private func takeInventory(
        profile: Profile, rsyncPath: String, in workspace: URL, onLog: ((String) -> Void)?
    ) async throws -> SideInventory {
        let empty = workspace.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let excludeFile = try RsyncArguments.writeExcludeFile(
            Profile.systemExcludes, in: workspace
        )

        let plan = ProcessPlan(
            executable: rsyncPath,
            arguments: RsyncArguments.inventoryArguments(
                profile: profile,
                options: .init(
                    side: .local,
                    emptyDirectory: empty.path,
                    excludeFile: excludeFile,
                    wantsRawNames: true
                )
            )
        )
        onLog?("$ \(plan.displayCommand)")

        var entries: [InventoryEntry] = []
        var errors: [String] = []
        let lock = NSLock()
        let status = try await runner.run(
            plan,
            onOutput: { line in
                guard let entry = ItemizeParser.parseInventoryLine(line, withChecksum: false)
                else { return }
                lock.lock()
                entries.append(entry)
                lock.unlock()
            },
            onError: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                onLog?(trimmed)
                lock.lock()
                errors.append(trimmed)
                lock.unlock()
            }
        )
        // 24 heisst nur: waehrend des Laufs sind Quelldateien verschwunden.
        guard status == 0 || status == 24 else {
            throw RsyncError.failed(status: status, detail: errors.last ?? "keine Fehlermeldung")
        }
        return InventoryBuilder.build(from: entries)
    }

    private func pack(
        profile: Profile,
        partial: URL,
        listURL: URL,
        total: Int,
        onLog: ((String) -> Void)?,
        onProgress: ((TransferProgress) -> Void)?
    ) async throws -> [String] {
        let plan = ProcessPlan(
            executable: zipPath,
            arguments: ZipArguments.arguments(archive: partial.path),
            workingDirectory: profile.localRoot,
            input: .file(listURL.path)
        )
        onLog?("$ \(plan.displayCommand)")

        var completed = 0
        var missing: [String] = []
        var warnings: [String] = []
        var lastReport = Date.distantPast
        let lock = NSLock()

        let status: Int32
        do {
            status = try await runner.run(
                plan,
                onOutput: { line in
                    // Die adding-Zeilen gehen bewusst NICHT ins Protokoll: das
                    // deckelt auf 2000 Zeilen und kostet je Aufruf O(n).
                    switch ZipOutputParser.classify(line) {
                    case .added(let path):
                        lock.lock()
                        completed += 1
                        let count = completed
                        let due =
                            count % Self.progressStride == 0
                            || Date().timeIntervalSince(lastReport) >= Self.progressInterval
                            || count == total
                        if due { lastReport = Date() }
                        lock.unlock()
                        if due {
                            onProgress?(
                                TransferProgress(
                                    completed: count, total: max(total, count), currentPath: path
                                )
                            )
                        }
                    case .notMatched(let name):
                        lock.lock()
                        missing.append(name)
                        lock.unlock()
                    case .other:
                        break
                    }
                },
                onError: { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    if case .notMatched(let name) = ZipOutputParser.classify(trimmed) {
                        lock.lock()
                        missing.append(name)
                        lock.unlock()
                        return
                    }
                    onLog?(trimmed)
                    lock.lock()
                    warnings.append(trimmed)
                    lock.unlock()
                }
            )
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }

        // 18 heisst: einzelne Dateien liessen sich nicht lesen. Das Archiv ist
        // trotzdem entstanden, das ist eine Warnung und kein Fehlschlag.
        guard status == 0 || status == 18 else {
            try? FileManager.default.removeItem(at: partial)
            throw BackupError.zipFailed(
                status: status, detail: warnings.last ?? "keine Fehlermeldung"
            )
        }
        if !missing.isEmpty {
            onLog?("\(missing.count) Einträge fehlen im Archiv, siehe Warnungen.")
        }
        return missing
    }
}
