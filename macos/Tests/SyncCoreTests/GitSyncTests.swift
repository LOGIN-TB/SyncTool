import Foundation
import Testing

@testable import SyncCore

/// Antwortet auf git-Aufrufe mit hinterlegten Ergebnissen, statt git zu starten.
private final class FakeGit: GitCommandRunning, @unchecked Sendable {
    /// Antwort je Unterbefehl. Der Schluessel ist das erste Argument.
    var answers: [String: CommandResult] = [:]
    /// Antworten, die nur beim ersten passenden Aufruf gelten. Damit lassen
    /// sich `rev-parse` als HEAD-Frage und als MERGE_HEAD-Sonde trennen.
    var byArguments: [[String]: CommandResult] = [:]
    var calls: [[String]] = []

    func run(_ arguments: [String], in directory: String) async throws -> CommandResult {
        calls.append(arguments)
        if let exact = byArguments[arguments] { return exact }
        if let answer = answers[arguments[0]] { return answer }
        return FakeGit.result(status: 1)
    }

    static func result(status: Int32 = 0, out: String = "", err: String = "") -> CommandResult {
        CommandResult(status: status, standardOutput: out, standardError: err)
    }
}

@Suite("Abgleich mit der Gegenstelle")
struct GitSyncTests {
    private let archive = URL(fileURLWithPath: "/tmp/Projekt-bak-2026-09-14.zip")

    private func sync(
        _ git: FakeGit, snapshot: ((String) async throws -> URL)? = nil
    ) -> GitSync {
        GitSync(runner: git, snapshot: snapshot ?? { _ in self.archive })
    }

    /// Die Vorgabe: HEAD auf `main`, Upstream `origin/main`, kein Merge offen.
    private func healthyGit(behind: Int, ahead: Int, dirty: String = "") -> FakeGit {
        let git = FakeGit()
        git.answers["symbolic-ref"] = FakeGit.result(out: "main\n")
        git.answers["fetch"] = FakeGit.result()
        git.answers["status"] = FakeGit.result(out: dirty)
        git.answers["merge"] = FakeGit.result()
        git.byArguments[["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]] =
            FakeGit.result(out: "origin/main\n")
        git.byArguments[["rev-list", "--left-right", "--count", "origin/main...HEAD"]] =
            FakeGit.result(out: "\(behind)\t\(ahead)\n")
        return git
    }

    private func run(_ git: FakeGit, snapshot: ((String) async throws -> URL)? = nil) async
        -> GitRepoResult
    {
        await sync(git, snapshot: snapshot)
            .run(roots: ["Projekt/"], localRoot: "/Users/test/Develop")[0]
    }

    @Test("Auf gleichem Stand wird nichts angefasst")
    func upToDateDoesNothing() async {
        let git = healthyGit(behind: 0, ahead: 0)
        let result = await run(git)
        #expect(result.action == .upToDate)
        #expect(!git.calls.contains { $0.first == "merge" })
    }

    @Test("Nur zurück und sauber: es wird vorgespult")
    func behindAndCleanFastForwards() async {
        let git = healthyGit(behind: 57, ahead: 0)
        let result = await run(git)
        #expect(result.action == .fastForwarded(commits: 57))
        #expect(result.behind == 57)
        #expect(result.archive == archive)
        #expect(git.calls.contains(["merge", "--ff-only", "origin/main"]))
    }

    @Test("Vor dem Vorspulen wird gesichert")
    func snapshotComesFirst() async {
        var order: [String] = []
        let git = healthyGit(behind: 3, ahead: 0)
        _ = await run(git, snapshot: { _ in
            order.append("sicherung")
            return self.archive
        })
        #expect(order == ["sicherung"])
    }

    @Test("Scheitert die Sicherung, wird nicht vorgespult")
    func withoutSnapshotNoChange() async {
        let git = healthyGit(behind: 3, ahead: 0)
        let result = await run(git, snapshot: { _ in throw BackupError.nothingToArchive })
        #expect(!git.calls.contains { $0.first == "merge" })
        if case .failed = result.action {} else { Issue.record("kein Fehlschlag gemeldet") }
    }

    @Test("Eine schmutzige Arbeitskopie bleibt in Ruhe")
    func dirtyWorktreeIsSkipped() async {
        let git = healthyGit(behind: 7, ahead: 0, dirty: " M datei.swift\n")
        let result = await run(git)
        #expect(result.action == .skipped(.dirtyWorktree))
        #expect(!git.calls.contains { $0.first == "merge" })
    }

    /// In einem Entwicklungsordner liegt fast immer etwas Unbekanntes herum.
    /// Zaehlte das als schmutzig, liefe der Vorspulschritt so gut wie nie.
    @Test("Unversionierte Dateien halten den Vorspulschritt nicht auf")
    func untrackedFilesDoNotBlock() async {
        let git = healthyGit(behind: 2, ahead: 0)
        let result = await run(git)
        #expect(result.action == .fastForwarded(commits: 2))
        #expect(git.calls.contains(["status", "--porcelain", "--untracked-files=no"]))
    }

    @Test("Verweigert git das Vorspulen, steht der Grund in der Zeile des Repos")
    func refusedFastForwardIsReported() async {
        // Der Netz darunter: `merge --ff-only` verweigert von sich aus, wenn ein
        // ankommender Commit eine unbekannte Datei ueberschreiben wuerde.
        let git = healthyGit(behind: 2, ahead: 0)
        git.answers["merge"] = FakeGit.result(
            status: 128, err: "untracked working tree files would be overwritten"
        )
        let result = await run(git)
        #expect(result.action == .failed("untracked working tree files would be overwritten"))
    }

    // MARK: - Zusammenfassung

    private func result(behind: Int, action: GitAction) -> GitRepoResult {
        GitRepoResult(root: "R/", branch: "main", behind: behind, action: action)
    }

    @Test("Ein Repo, das weiter zurückhängt, verschwindet nicht in der Meldung")
    func summaryNamesWhatIsStillBehind() {
        // Genau der Fehler aus dem Feld: zwei Repos hingen zurück, keines liess
        // sich vorspulen, und die Meldung sagte "Kein Repo hing zurück".
        let text = GitSync.summary(of: [
            result(behind: 2, action: .skipped(.dirtyWorktree)),
            result(behind: 5, action: .skipped(.diverged)),
        ])
        #expect(text == "2 Repos hängen weiter zurück.")
    }

    @Test("Vorgespult und hängengeblieben stehen nebeneinander")
    func summaryCombinesBothOutcomes() {
        let text = GitSync.summary(of: [
            result(behind: 3, action: .fastForwarded(commits: 3)),
            result(behind: 1, action: .skipped(.dirtyWorktree)),
            result(behind: 0, action: .failed("kaputt")),
        ])
        #expect(text == "1 Repo vorgespult, 1 Repo hängt weiter zurück, 1 mit Fehler.")
    }

    @Test("Ist alles auf Stand, sagt die Meldung das auch")
    func summaryWhenEverythingIsLevel() {
        let text = GitSync.summary(of: [
            result(behind: 0, action: .upToDate),
            result(behind: 0, action: .upToDate),
        ])
        #expect(text == "Alle Repos stehen auf dem Stand ihrer Gegenstelle.")
    }

    @Test("Nur ein Repo auf Stand gehört nicht ins Statusfenster")
    func onlyNoteworthyResultsNeedAttention() {
        #expect(!result(behind: 0, action: .upToDate).needsAttention)
        #expect(result(behind: 2, action: .skipped(.dirtyWorktree)).needsAttention)
        #expect(result(behind: 2, action: .skipped(.dirtyWorktree)).stillBehind)
        #expect(!result(behind: 2, action: .fastForwarded(commits: 2)).stillBehind)
    }

    @Test("Beide Seiten haben eigene Commits: da entscheidet ein Mensch")
    func divergedIsSkipped() async {
        let result = await run(healthyGit(behind: 2, ahead: 1))
        #expect(result.action == .skipped(.diverged))
        #expect(result.behind == 2)
        #expect(result.ahead == 1)
    }

    @Test("Nur voraus heißt: hier steht ein push aus, mehr nicht")
    func aheadOnlyIsReported() async {
        let git = healthyGit(behind: 0, ahead: 4)
        let result = await run(git)
        #expect(result.action == .pushPending(commits: 4))
        #expect(!git.calls.contains { $0.first == "merge" })
    }

    @Test("Ohne Zweig auf der Gegenstelle gibt es nichts abzugleichen")
    func withoutUpstreamNothingHappens() async {
        let git = healthyGit(behind: 3, ahead: 0)
        git.byArguments[["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]] =
            FakeGit.result(status: 128, err: "no upstream")
        let result = await run(git)
        #expect(result.action == .skipped(.noUpstream))
        #expect(!git.calls.contains { $0.first == "fetch" })
    }

    @Test("Ein abgelöster HEAD wird gemeldet, nicht bewegt")
    func detachedHeadIsSkipped() async {
        let git = healthyGit(behind: 3, ahead: 0)
        git.answers["symbolic-ref"] = FakeGit.result(status: 1)
        let result = await run(git)
        #expect(result.action == .skipped(.detachedHead))
    }

    @Test("Ein offener Merge hält den Abgleich an")
    func mergeInProgressIsSkipped() async {
        let git = healthyGit(behind: 3, ahead: 0)
        git.byArguments[["rev-parse", "--verify", "--quiet", "MERGE_HEAD"]] =
            FakeGit.result(out: "abc123\n")
        let result = await run(git)
        #expect(result.action == .skipped(.operationInProgress))
        #expect(!git.calls.contains { $0.first == "fetch" })
    }

    @Test("Ein gescheitertes Holen hält die anderen Repos nicht auf")
    func failedFetchDoesNotStopTheRun() async {
        let git = healthyGit(behind: 3, ahead: 0)
        git.answers["fetch"] = FakeGit.result(status: 128, err: "could not read Username")
        let results = await sync(git).run(
            roots: ["Eins/", "Zwei/"], localRoot: "/Users/test/Develop"
        )
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.action == .failed("could not read Username") })
    }

    @Test("git wird ohne Rückfragen gestartet")
    func gitNeverAsksForInput() {
        // Eine Menueleisten-App startet nicht aus der Shell. Ohne die Riegel
        // wartet `git fetch` auf eine Eingabe, die nie kommt.
        let environment = GitCommandRunner.environment
        #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(environment["GIT_ASKPASS"] == "/usr/bin/false")
        #expect(environment["SSH_ASKPASS"] == "/usr/bin/false")
        // Die uebrige Umgebung muss mit, daraus kommt HOME.
        #expect(environment["HOME"] != nil)
    }

    @Test("Der Zählstand wird aus der git-Ausgabe gelesen")
    func countsAreParsed() {
        #expect(GitSync.parseCounts("57\t0\n")?.behind == 57)
        #expect(GitSync.parseCounts("2\t3")?.ahead == 3)
        #expect(GitSync.parseCounts("kaputt") == nil)
        #expect(GitSync.parseCounts("") == nil)
    }
}
