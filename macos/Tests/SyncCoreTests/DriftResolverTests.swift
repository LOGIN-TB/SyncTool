import Foundation
import Testing

@testable import SyncCore

@Suite("Richtungsbestimmung")
struct DriftResolverTests {
    private let base = Date(timeIntervalSince1970: 1_770_000_000)

    private func entry(
        _ path: String,
        type: ItemType = .file,
        size: Int64 = 100,
        offset: TimeInterval = 0,
        linkTarget: String? = nil,
        checksum: String? = nil
    ) -> InventoryEntry {
        InventoryEntry(
            path: path,
            type: type,
            size: size,
            modified: base.addingTimeInterval(offset),
            linkTarget: linkTarget,
            checksum: checksum
        )
    }

    private func side(_ entries: [InventoryEntry]) -> SideInventory {
        InventoryBuilder.build(from: entries)
    }

    private func resolve(
        remote: [InventoryEntry] = [],
        local: [InventoryEntry] = [],
        lastSync: Date? = nil,
        knownPaths: Set<String>? = nil
    ) -> SyncStatus {
        DriftResolver.resolve(
            remote: side(remote), local: side(local),
            lastSync: lastSync, knownPaths: knownPaths
        )
    }

    @Test("Ohne Vorgeschichte braucht das, was es nur auf einer Seite gibt, keinen Zeitvergleich")
    func fileOnlyOnOneSide() {
        let status = resolve(remote: [entry("nur-remote.txt")], local: [entry("nur-lokal.txt")])
        #expect(status.incoming.map(\.path) == ["nur-remote.txt"])
        #expect(status.incoming.first?.reason == .onlyRemote)
        #expect(status.outgoing.map(\.path) == ["nur-lokal.txt"])
        #expect(status.outgoing.first?.reason == .onlyLocal)
        #expect(status.conflicts.isEmpty)
    }

    @Test("Dieselbe Datei auf beiden Seiten entscheidet der Zeitstempel")
    func sameFileOnBothSidesResolvedByTimestamp() {
        let status = resolve(
            remote: [entry("gemeinsam.txt", size: 200, offset: 600)],
            local: [entry("gemeinsam.txt", size: 100, offset: 0)]
        )
        #expect(status.incoming.map(\.path) == ["gemeinsam.txt"])
        #expect(status.incoming.first?.reason == .remoteNewer)
        #expect(status.outgoing.isEmpty)
    }

    @Test("Lokal neuer heißt hochladen")
    func localNewerGoesOutgoing() {
        let status = resolve(
            remote: [entry("gemeinsam.txt", size: 100, offset: 0)],
            local: [entry("gemeinsam.txt", size: 200, offset: 600)]
        )
        #expect(status.outgoing.first?.reason == .localNewer)
        #expect(status.incoming.isEmpty)
    }

    @Test("Gleiche Zeit, andere Größe ist ein Konflikt")
    func equalTimestampsDifferentSize() {
        let status = resolve(
            remote: [entry("gemeinsam.txt", size: 100)],
            local: [entry("gemeinsam.txt", size: 250)]
        )
        #expect(status.conflicts.count == 1)
        #expect(status.conflicts.first?.reason == .sameTimeDifferentContent)
        #expect(status.conflicts.first?.remoteSize == 100)
        #expect(status.conflicts.first?.localSize == 250)
    }

    @Test("Gleiche Zeit und gleiche Größe heißt gleich, genau wie bei rsync")
    func equalTimestampAndSizeIsInSync() {
        let status = resolve(
            remote: [entry("gemeinsam.txt", size: 100)],
            local: [entry("gemeinsam.txt", size: 100)]
        )
        #expect(status.isInSync)
    }

    /// Genau der Fall, in dem getrenntes Pull/Push sonst still Arbeit verwirft.
    @Test("Beidseitig geändert schlägt „der Neuere gewinnt“")
    func bothSidesChangedSinceLastSync() {
        let status = resolve(
            remote: [entry("gemeinsam.txt", size: 200, offset: 600)],
            local: [entry("gemeinsam.txt", size: 100, offset: 300)],
            lastSync: base
        )
        #expect(status.incoming.isEmpty)
        #expect(status.outgoing.isEmpty)
        #expect(status.conflicts.first?.reason == .bothChangedSinceLastSync)
    }

    @Test("Nur eine Seite geändert bleibt eindeutig")
    func onlyOneSideChangedSinceLastSync() {
        let status = resolve(
            remote: [entry("gemeinsam.txt", size: 200, offset: 600)],
            local: [entry("gemeinsam.txt", size: 100, offset: -600)],
            lastSync: base
        )
        #expect(status.incoming.first?.reason == .remoteNewer)
        #expect(status.conflicts.isEmpty)
    }

    @Test("Eine Sekunde Unterschied gilt noch als gleiche Zeit")
    func timestampsWithinTolerance() {
        let status = resolve(
            remote: [entry("gemeinsam.txt", size: 1, offset: 1)],
            local: [entry("gemeinsam.txt", size: 2, offset: 0)]
        )
        #expect(status.conflicts.first?.reason == .sameTimeDifferentContent)
    }

    @Test("Fehlender Zeitstempel führt nicht zu einer Ratsentscheidung")
    func missingTimestampFallsBackToConflict() {
        let blind = InventoryEntry(path: "x.txt", type: .file, size: 1, modified: nil)
        let status = resolve(remote: [blind], local: [entry("x.txt", size: 2)])
        #expect(status.conflicts.first?.reason == .unknownTimestamps)
    }

    // MARK: - Prüfsummen

    /// Der Grund, warum `useChecksum` etwas bringt: gleicher Inhalt bei
    /// verschobenem Zeitstempel ist nichts zu tun, kein Download.
    @Test("Gleiche Prüfsumme sticht jeden Zeitvergleich")
    func equalChecksumBeatsTimestamps() {
        let status = resolve(
            remote: [entry("a.txt", size: 100, offset: 600, checksum: "abc")],
            local: [entry("a.txt", size: 100, offset: 0, checksum: "abc")]
        )
        #expect(status.isInSync)
    }

    @Test("Verschiedene Prüfsumme bei gleicher Zeit bleibt ein Konflikt")
    func differentChecksumAtSameTimeIsAConflict() {
        let status = resolve(
            remote: [entry("a.txt", size: 100, checksum: "abc")],
            local: [entry("a.txt", size: 100, checksum: "xyz")]
        )
        #expect(status.conflicts.first?.reason == .sameTimeDifferentContent)
    }

    // MARK: - Verzeichnisse und Symlinks

    /// Vorher fielen Verzeichnisse komplett aus der Auswertung. Ein leerer
    /// Ordner kam damit nie auf die andere Seite.
    @Test("Ein leerer Ordner nur auf einer Seite wird gemeldet")
    func emptyDirectoryOnOneSideIsReported() {
        let status = resolve(local: [entry("leer/", type: .directory)])
        #expect(status.outgoing.map(\.path) == ["leer/"])
        #expect(!status.isInSync)
    }

    /// Sonst stünde jeder Ordner zusätzlich zu seinen Dateien in der Liste.
    @Test("Ein Ordner mit Inhalt wird von seinen Dateien mitgezogen")
    func directoryWithChildrenIsNotListedSeparately() {
        let status = resolve(
            local: [entry("unter/", type: .directory), entry("unter/datei.txt")]
        )
        #expect(status.outgoing.map(\.path) == ["unter/datei.txt"])
    }

    @Test("Ein Ordner auf beiden Seiten wird nie an Größe oder Zeit gemessen")
    func directoriesAreComparedByExistenceOnly() {
        let status = resolve(
            remote: [entry("unter/", type: .directory, size: 192, offset: 900)],
            local: [entry("unter/", type: .directory, size: 640, offset: 0)]
        )
        #expect(status.isInSync)
    }

    /// Zeitstempel auf einem Symlink lassen sich nicht zuverlaessig setzen.
    /// Frueher meldete rsync die deshalb nach jedem Lauf erneut.
    @Test("Ein Symlink mit gleichem Ziel ist gleich, egal wie alt")
    func symlinkWithSameTargetIsInSync() {
        let status = resolve(
            remote: [entry("v.txt", type: .symlink, size: 9, offset: 900, linkTarget: "a.txt")],
            local: [entry("v.txt", type: .symlink, size: 9, offset: 0, linkTarget: "a.txt")]
        )
        #expect(status.isInSync)
    }

    @Test("Ein umgehängter Symlink ist eine Abweichung")
    func retargetedSymlinkIsDrift() {
        let status = resolve(
            remote: [entry("v.txt", type: .symlink, size: 9, offset: 900, linkTarget: "a.txt")],
            local: [entry("v.txt", type: .symlink, size: 9, offset: 0, linkTarget: "b.txt")]
        )
        #expect(status.incoming.map(\.path) == ["v.txt"])
    }

    // MARK: - Löschungen

    @Test("Lokal gelöscht heißt Löschung beim Hochladen, nicht Download")
    func deletedLocallyBecomesPushDeletion() {
        let status = resolve(
            remote: [entry("weg.txt")], lastSync: base, knownPaths: ["weg.txt"]
        )
        #expect(status.incoming.isEmpty)
        #expect(status.deletionsOnPush.map(\.path) == ["weg.txt"])
        #expect(status.deletionsOnPull.isEmpty)
        #expect(status.protectedOnPush.isEmpty)
        #expect(!status.isInSync)
    }

    @Test("Neu auf dem Server bleibt ein Download und wird beim Hochladen geschützt")
    func newOnServerStaysIncoming() {
        let status = resolve(
            remote: [entry("neu.txt")], lastSync: base, knownPaths: ["andere.txt"]
        )
        #expect(status.incoming.map(\.path) == ["neu.txt"])
        #expect(status.deletionsOnPush.isEmpty)
        #expect(status.protectedOnPush == ["neu.txt"])
    }

    @Test("Auf dem Server gelöscht heißt Löschung beim Herunterladen")
    func deletedOnServerBecomesPullDeletion() {
        let status = resolve(
            local: [entry("weg.txt")], lastSync: base, knownPaths: ["weg.txt"]
        )
        #expect(status.outgoing.isEmpty)
        #expect(status.deletionsOnPull.map(\.path) == ["weg.txt"])
        #expect(status.protectedOnPull.isEmpty)
    }

    @Test("Lokal neu angelegt bleibt ein Upload und wird beim Herunterladen geschützt")
    func newLocalStaysOutgoing() {
        let status = resolve(local: [entry("neu.txt")], lastSync: base, knownPaths: [])
        #expect(status.outgoing.map(\.path) == ["neu.txt"])
        #expect(status.deletionsOnPull.isEmpty)
        #expect(status.protectedOnPull == ["neu.txt"])
    }

    // MARK: - Übergang ohne Bestandsliste

    @Test("Ohne Bestandsliste entscheidet der Zeitstempel gegen den letzten Abgleich")
    func timestampFallbackWithoutInventory() {
        // Älter als der letzte Abgleich: war damals schon da, also lokal gelöscht.
        let alt = resolve(remote: [entry("alt.txt", offset: -600)], lastSync: base)
        #expect(alt.incoming.isEmpty)
        #expect(alt.deletionsOnPush.map(\.path) == ["alt.txt"])

        // Jünger: erst danach auf dem Server entstanden.
        let neu = resolve(remote: [entry("neu.txt", offset: 600)], lastSync: base)
        #expect(neu.incoming.map(\.path) == ["neu.txt"])
        #expect(neu.deletionsOnPush.isEmpty)
    }

    @Test("Ohne letzten Abgleich bleibt alles ein Download")
    func withoutLastSyncNothingCountsAsDeleted() {
        let status = resolve(remote: [entry("x.txt", offset: -600)])
        #expect(status.incoming.map(\.path) == ["x.txt"])
        #expect(status.deletionsOnPush.isEmpty)
    }

    @Test("Eine leere Bestandsliste sticht die Zeitstempel-Regel aus")
    func emptyInventoryBeatsTheHeuristic() {
        let status = resolve(
            remote: [entry("alt.txt", offset: -600)], lastSync: base, knownPaths: []
        )
        #expect(status.incoming.map(\.path) == ["alt.txt"])
        #expect(status.deletionsOnPush.isEmpty)
    }

    // MARK: - Bilanz

    @Test("Die Bilanz zählt beide Seiten und die Ausschlüsse")
    func reportCountsBothSides() {
        let status = DriftResolver.resolve(
            remote: side([entry("a.txt", size: 10), entry("d/", type: .directory)]),
            local: side([entry("a.txt", size: 10), entry("d/", type: .directory)]),
            lastSync: nil,
            excludedPaths: [".DS_Store", "build/"]
        )
        #expect(status.isInSync)
        #expect(status.report.remoteFiles == 1)
        #expect(status.report.remoteDirectories == 1)
        #expect(status.report.remoteBytes == 10)
        #expect(status.report.localFiles == 1)
        #expect(status.report.excludedCount == 2)
        // Die groessten Zweige zuerst, bei Gleichstand alphabetisch.
        #expect(status.report.excluded.map(\.path) == [".DS_Store", "build/"])
    }

    @Test("Die gemessenen Bestände hängen am Ergebnis")
    func measuredPathsTravelWithTheStatus() {
        let status = resolve(remote: [entry("a.txt")], local: [entry("b.txt")])
        #expect(status.remotePaths == ["a.txt"])
        #expect(status.localPaths == ["b.txt"])
    }

    @Test("Ohne Abweichungen ist alles auf gleichem Stand")
    func inSyncWhenNothingDiffers() {
        let status = resolve()
        #expect(status.isInSync)
        #expect(status.incomingBytes == 0)
        #expect(status.outgoingBytes == 0)
    }
}
