import Foundation

/// Was SyncTool an einem Repo getan hat, oder warum nicht.
public enum GitAction: Sendable, Equatable {
    /// Der Zweig liegt auf dem Stand der Gegenstelle.
    case upToDate
    /// Vorgespult, ohne zusammenzufuehren.
    case fastForwarded(commits: Int)
    /// Hier liegen Commits, die noch nirgends sonst liegen. Gepusht wird nicht:
    /// Veroeffentlichen bleibt eine Handbewegung.
    case pushPending(commits: Int)
    case skipped(GitSkipReason)
    case failed(String)

    public var changedSomething: Bool {
        if case .fastForwarded = self { return true }
        return false
    }
}

public enum GitSkipReason: String, Sendable {
    case noUpstream
    case detachedHead
    case operationInProgress
    case dirtyWorktree
    case diverged
    case noBackup

    public var label: String {
        switch self {
        case .noUpstream: return "kein Zweig auf der Gegenstelle"
        case .detachedHead: return "HEAD hängt an keinem Zweig"
        case .operationInProgress: return "ein Merge oder Rebase läuft noch"
        case .dirtyWorktree: return "Arbeitskopie nicht sauber"
        case .diverged: return "beide Seiten haben eigene Commits"
        case .noBackup: return "kein Zielordner für die Sicherung im Profil"
        }
    }
}

public struct GitRepoResult: Sendable, Identifiable {
    public var id: String { root }
    /// Stamm des Repos, relativ zum Stammordner. Leer heisst: der Stammordner.
    public let root: String
    /// Der Zweig, auf dem HEAD steht. Leer, wenn HEAD abgeloest ist.
    public let branch: String
    public let behind: Int
    public let ahead: Int
    public let action: GitAction
    /// Der Schnappschuss, falls einer gezogen wurde.
    public let archive: URL?

    public init(
        root: String,
        branch: String,
        behind: Int = 0,
        ahead: Int = 0,
        action: GitAction,
        archive: URL? = nil
    ) {
        self.root = root
        self.branch = branch
        self.behind = behind
        self.ahead = ahead
        self.action = action
        self.archive = archive
    }

    public var displayName: String { root.isEmpty ? "Stammordner" : String(root.dropLast()) }

    /// Gehoert das ins Statusfenster? Ein Repo auf gleichem Stand gehoert nicht
    /// dorthin, sonst steht dort eine Liste, in der nichts zu tun ist.
    public var needsAttention: Bool {
        if case .upToDate = action { return false }
        return true
    }

    /// Haengt das Repo nach diesem Lauf immer noch hinter seiner Gegenstelle?
    public var stillBehind: Bool { behind > 0 && !action.changedSomething }

    /// Steht das Repo hier nachweislich auf dem Stand seiner Gegenstelle?
    ///
    /// Nur dann taugt es als Schiedsrichter fuer einen Gleichstand zwischen
    /// Rechner und Sync-Ziel. `pushPending` reicht bewusst nicht: dort liegen
    /// Commits, die noch nirgends sonst liegen.
    public var matchesRemote: Bool {
        switch action {
        case .upToDate, .fastForwarded: return true
        case .pushPending, .skipped, .failed: return false
        }
    }

    /// Ein Satz fuer das Statusfenster.
    public var summary: String {
        switch action {
        case .upToDate: return "auf dem Stand der Gegenstelle"
        case .fastForwarded(let commits):
            return "\(Format.count(commits, singular: "Commit", plural: "Commits")) vorgespult"
        case .pushPending(let commits):
            return "\(Format.count(commits, singular: "Commit", plural: "Commits")) "
                + "noch nicht gepusht"
        case .skipped(let reason):
            return behind > 0
                ? "\(behind) zurück, ausgelassen: \(reason.label)" : "ausgelassen: \(reason.label)"
        case .failed(let detail): return detail
        }
    }
}

/// Fuehrt `git` aus. Als Protokoll, damit sich die Entscheidungstabelle ohne
/// echte Repos pruefen laesst.
public protocol GitCommandRunning: Sendable {
    func run(_ arguments: [String], in directory: String) async throws -> CommandResult
}

public struct GitCommandRunner: GitCommandRunning {
    private let gitPath: String
    private let timeout: TimeInterval

    public init(gitPath: String, timeout: TimeInterval = 300) {
        self.gitPath = gitPath
        self.timeout = timeout
    }

    public func run(_ arguments: [String], in directory: String) async throws -> CommandResult {
        try await CommandRunner.run(
            executable: gitPath,
            arguments: ["-C", directory] + arguments,
            environment: Self.environment,
            timeout: timeout
        )
    }

    /// Die Umgebung des Elternprozesses plus drei Riegel.
    ///
    /// Eine Menueleisten-App startet nicht aus der Shell. Ohne die Riegel
    /// wartet `git fetch` bei fehlenden Zugangsdaten auf eine Eingabe, die nie
    /// kommt, und der Lauf haengt. Die uebrige Umgebung muss mit: daraus kommen
    /// `HOME` fuer die Konfiguration, der Schluesselbund-Helfer und
    /// `SSH_AUTH_SOCK` fuer Gegenstellen ueber ssh.
    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS"] = "/usr/bin/false"
        // Ein Statuslauf soll die Index-Sperre nicht anfassen, sonst stolpert
        // eine Shell, die daneben im selben Repo arbeitet.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        return environment
    }
}

/// Gleicht die Repos im Stammordner mit ihrer Gegenstelle ab.
///
/// Die Gegenstelle ist das fuehrende System, nicht die Storage Box: dort liegt
/// der Stand, auf den sich beide Rechner berufen. Vorgespult wird nur, wenn das
/// ohne Zusammenfuehren geht und die Arbeitskopie sauber ist. Alles andere wird
/// gemeldet, nicht geraten.
public final class GitSync {
    private let runner: GitCommandRunning
    /// Zieht vor einem Eingriff einen Schnappschuss des Repos und liefert das
    /// Archiv. Gibt es keinen Weg dorthin, wirft der Rueckruf, und der Eingriff
    /// unterbleibt: ohne Sicherung kein Eingriff.
    private let snapshot: (String) async throws -> URL

    public init(runner: GitCommandRunning, snapshot: @escaping (String) async throws -> URL) {
        self.runner = runner
        self.snapshot = snapshot
    }

    /// `roots` sind Repo-Staemme relativ zum Stammordner, wie
    /// `GitRepositories.roots(in:)` sie liefert.
    public func run(
        roots: [String],
        localRoot: String,
        onLog: ((String) -> Void)? = nil
    ) async -> [GitRepoResult] {
        var results: [GitRepoResult] = []
        for root in roots {
            let directory = (localRoot as NSString).appendingPathComponent(root)
            do {
                results.append(
                    try await reconcile(root: root, directory: directory, onLog: onLog)
                )
            } catch {
                // Ein Repo, das klemmt, haelt die anderen nicht auf.
                onLog?("\(name(root)): \(error.localizedDescription)")
                results.append(
                    GitRepoResult(
                        root: root, branch: "", action: .failed(error.localizedDescription)
                    )
                )
            }
        }
        return results
    }

    /// Was der Lauf ergeben hat, in einem Satz.
    ///
    /// Vorher stand hier "Kein Repo hing hinter seiner Gegenstelle zurueck",
    /// sobald nichts vorgespult wurde. Das war falsch, sobald ein Repo zwar
    /// zurueckhing, aber ausgelassen werden musste, und genau das ist der Fall,
    /// den der Nutzer sehen will.
    public static func summary(of results: [GitRepoResult]) -> String {
        let forwarded = results.count { $0.action.changedSomething }
        let stuck = results.count(where: \.stillBehind)
        let failed = results.count { result in
            if case .failed = result.action { return true }
            return false
        }

        var parts: [String] = []
        if forwarded > 0 {
            parts.append(
                Format.count(forwarded, singular: "Repo", plural: "Repos") + " vorgespult"
            )
        }
        if stuck > 0 {
            parts.append(
                Format.count(stuck, singular: "Repo hängt", plural: "Repos hängen")
                    + " weiter zurück"
            )
        }
        if failed > 0 {
            parts.append("\(failed) mit Fehler")
        }
        guard !parts.isEmpty else { return "Alle Repos stehen auf dem Stand ihrer Gegenstelle." }
        return parts.joined(separator: ", ") + "."
    }

    // MARK: - Intern

    private func name(_ root: String) -> String {
        root.isEmpty ? "Stammordner" : String(root.dropLast())
    }

    private func reconcile(
        root: String, directory: String, onLog: ((String) -> Void)?
    ) async throws -> GitRepoResult {
        let head = try await runner.run(["symbolic-ref", "--short", "-q", "HEAD"], in: directory)
        guard head.succeeded else {
            return GitRepoResult(root: root, branch: "", action: .skipped(.detachedHead))
        }
        let branch = head.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        let upstream = try await runner.run(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: directory
        )
        guard upstream.succeeded else {
            return GitRepoResult(root: root, branch: branch, action: .skipped(.noUpstream))
        }
        let tracked = upstream.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        if try await isMidOperation(in: directory) {
            return GitRepoResult(
                root: root, branch: branch, action: .skipped(.operationInProgress)
            )
        }

        onLog?("\(name(root)): hole von \(tracked)")
        let fetch = try await runner.run(
            ["fetch", "--prune", "--no-write-fetch-head"], in: directory
        )
        guard fetch.succeeded else {
            // Kein Abbruch: ohne Shell fehlen einer Menueleisten-App manchmal
            // die Zugangsdaten, und die anderen Repos gehen das nichts an.
            return GitRepoResult(root: root, branch: branch, action: .failed(fetch.errorSummary))
        }

        let counts = try await runner.run(
            ["rev-list", "--left-right", "--count", "\(tracked)...HEAD"], in: directory
        )
        guard counts.succeeded, let (behind, ahead) = Self.parseCounts(counts.standardOutput) else {
            return GitRepoResult(
                root: root, branch: branch, action: .failed("Der Stand ließ sich nicht ablesen.")
            )
        }

        if behind == 0 {
            return GitRepoResult(
                root: root, branch: branch, behind: 0, ahead: ahead,
                action: ahead == 0 ? .upToDate : .pushPending(commits: ahead)
            )
        }
        if ahead > 0 {
            // Hier muss jemand entscheiden, und das ist nicht die Aufgabe
            // eines Abgleichs.
            return GitRepoResult(
                root: root, branch: branch, behind: behind, ahead: ahead,
                action: .skipped(.diverged)
            )
        }

        // `--untracked-files=no` mit Absicht: ein Vorspulschritt scheitert an
        // geaenderten versionierten Dateien, nicht an unbekannten. Wer in einem
        // Entwicklungsordner arbeitet, hat fast immer welche herumliegen, und
        // mit ihnen als Hinderungsgrund liefe dieser Schritt so gut wie nie.
        // Wuerde ein ankommender Commit eine davon ueberschreiben, verweigert
        // `merge --ff-only` von sich aus, und das faengt der Aufruf unten ab.
        let dirty = try await runner.run(
            ["status", "--porcelain", "--untracked-files=no"], in: directory
        )
        if !dirty.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return GitRepoResult(
                root: root, branch: branch, behind: behind, ahead: 0,
                action: .skipped(.dirtyWorktree)
            )
        }

        let archive = try await snapshot(root)
        onLog?("\(name(root)): gesichert nach \(archive.lastPathComponent)")

        let merge = try await runner.run(["merge", "--ff-only", tracked], in: directory)
        guard merge.succeeded else {
            return GitRepoResult(
                root: root, branch: branch, behind: behind, ahead: 0,
                action: .failed(merge.errorSummary), archive: archive
            )
        }
        return GitRepoResult(
            root: root, branch: branch, behind: behind, ahead: 0,
            action: .fastForwarded(commits: behind), archive: archive
        )
    }

    /// Laeuft gerade ein Merge oder ein Rebase?
    ///
    /// Ein Vorspulschritt mitten darin scheiterte ohnehin, aber mit einer
    /// Fehlermeldung statt mit einem Satz, der erklaert, was los ist.
    private func isMidOperation(in directory: String) async throws -> Bool {
        for reference in ["MERGE_HEAD", "REBASE_HEAD", "CHERRY_PICK_HEAD"] {
            let probe = try await runner.run(
                ["rev-parse", "--verify", "--quiet", reference], in: directory
            )
            if probe.succeeded { return true }
        }
        return false
    }

    /// `git rev-list --left-right --count a...b` schreibt "3\t0": links der
    /// Rueckstand, rechts der Vorsprung.
    static func parseCounts(_ output: String) -> (behind: Int, ahead: Int)? {
        let fields = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "\t" || $0 == " " })
        guard fields.count == 2, let behind = Int(fields[0]), let ahead = Int(fields[1]) else {
            return nil
        }
        return (behind, ahead)
    }
}
