import Foundation
import Testing

@testable import SyncCore

@Suite("Zeiger eines Repos")
struct GitRefsTests {
    private func sandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("synctool-refs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("packed-refs wird zerlegt, Kommentare und Tag-Ziele fallen raus")
    func packedRefsAreParsed() {
        let refs = GitRefs.parsePackedRefs(
            """
            # pack-refs with: peeled fully-peeled sorted
            aaa1111111111111111111111111111111111111 refs/heads/main
            bbb2222222222222222222222222222222222222 refs/tags/v1.0
            ^ccc3333333333333333333333333333333333333
            ddd4444444444444444444444444444444444444 refs/remotes/origin/main
            """
        )
        #expect(refs.count == 3)
        #expect(refs["refs/heads/main"] == "aaa1111111111111111111111111111111111111")
        #expect(refs["refs/remotes/origin/main"] == "ddd4444444444444444444444444444444444444")
        #expect(refs["refs/tags/v1.0"] == "bbb2222222222222222222222222222222222222")
    }

    @Test("Ein loser Ref sticht packed-refs")
    func looseRefWins() throws {
        let base = try sandbox()
        defer { try? FileManager.default.removeItem(at: base) }
        try write("ref: refs/heads/main\n", to: base.appendingPathComponent("HEAD"))
        try write(
            "aaa1111111111111111111111111111111111111 refs/heads/main\n",
            to: base.appendingPathComponent("packed-refs")
        )
        try write(
            "bbb2222222222222222222222222222222222222\n",
            to: base.appendingPathComponent("refs/heads/main")
        )

        let refs = GitRefs.read(gitDirectory: base.path)
        #expect(refs["refs/heads/main"] == "bbb2222222222222222222222222222222222222")
        #expect(refs["HEAD"] == "ref: refs/heads/main")
    }

    @Test("Ein Zweig mit Schrägstrich behält seinen ganzen Namen")
    func nestedBranchNames() throws {
        let base = try sandbox()
        defer { try? FileManager.default.removeItem(at: base) }
        try write("ref: refs/heads/feat/dach\n", to: base.appendingPathComponent("HEAD"))
        try write("ccc\n", to: base.appendingPathComponent("refs/heads/feat/dach"))

        #expect(GitRefs.read(gitDirectory: base.path)["refs/heads/feat/dach"] == "ccc")
    }

    /// Der gemeldete Fall: beide Rechner haben unabhaengig umgepackt. Die
    /// Dateien weichen ab, die Zeiger nicht.
    @Test("Nach beidseitigem Umpacken stehen dieselben Zeiger da")
    func repackingDoesNotMoveThePointers() throws {
        let one = try sandbox()
        let other = try sandbox()
        defer {
            try? FileManager.default.removeItem(at: one)
            try? FileManager.default.removeItem(at: other)
        }
        for base in [one, other] {
            try write("ref: refs/heads/main\n", to: base.appendingPathComponent("HEAD"))
            try write("aaa\n", to: base.appendingPathComponent("refs/heads/main"))
        }
        // Nur hier ein frisches Packfile, wie nach `git gc`.
        try write("binaerkram", to: one.appendingPathComponent("objects/pack/pack-1.pack"))
        try write("anderes", to: other.appendingPathComponent("objects/pack/pack-2.pack"))

        #expect(
            GitRefs.settled(
                GitRefs.read(gitDirectory: one.path), GitRefs.read(gitDirectory: other.path)
            )
        )
    }

    @Test("Ein bewegter Zweig ist kein gleicher Stand")
    func movedBranchIsNotSettled() throws {
        let one = try sandbox()
        let other = try sandbox()
        defer {
            try? FileManager.default.removeItem(at: one)
            try? FileManager.default.removeItem(at: other)
        }
        try write("aaa\n", to: one.appendingPathComponent("refs/heads/main"))
        try write("bbb\n", to: other.appendingPathComponent("refs/heads/main"))

        #expect(
            !GitRefs.settled(
                GitRefs.read(gitDirectory: one.path), GitRefs.read(gitDirectory: other.path)
            )
        )
    }

    /// Ohne gelesene Zeiger laesst sich nichts begruenden. Zwei leere Mengen
    /// duerfen deshalb nicht als "gleicher Stand" durchgehen.
    @Test("Nichts gelesen heißt nicht gleicher Stand")
    func emptyIsNeverSettled() {
        #expect(!GitRefs.settled([:], [:]))
        #expect(GitRefs.read(gitDirectory: "/gibt/es/nicht").isEmpty)
    }

    @Test("Ein zusätzlicher Zweig auf einer Seite zählt")
    func extraBranchCounts() throws {
        let one = try sandbox()
        let other = try sandbox()
        defer {
            try? FileManager.default.removeItem(at: one)
            try? FileManager.default.removeItem(at: other)
        }
        for base in [one, other] {
            try write("aaa\n", to: base.appendingPathComponent("refs/heads/main"))
        }
        try write("bbb\n", to: one.appendingPathComponent("refs/heads/nebenzweig"))

        #expect(
            !GitRefs.settled(
                GitRefs.read(gitDirectory: one.path), GitRefs.read(gitDirectory: other.path)
            )
        )
    }
}
