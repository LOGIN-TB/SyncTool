import Foundation
import Testing

@testable import SyncCore

@Suite("Zielordner der Archive")
struct BackupTargetTests {
    private func sandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("synctool-backup-ziel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func directory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Sonst packt das Backup von morgen das Archiv von heute mit ein.
    @Test("Ein Zielordner innerhalb des Quellordners wird abgelehnt")
    func destinationInsideSourceIsRejected() throws {
        let base = try sandbox()
        defer { try? FileManager.default.removeItem(at: base) }
        let quelle = try directory(base.appendingPathComponent("Develop"))
        let ziel = try directory(quelle.appendingPathComponent("backups"))

        #expect(BackupTarget.isInside(ziel, of: quelle))
        #expect(throws: BackupTargetError.self) {
            try BackupTarget.validate(
                destination: ziel.path, source: quelle.path, requiredBytes: 0
            )
        }
    }

    @Test("Der Quellordner selbst als Ziel wird abgelehnt")
    func sourceAsDestinationIsRejected() throws {
        let base = try sandbox()
        defer { try? FileManager.default.removeItem(at: base) }
        let quelle = try directory(base.appendingPathComponent("Develop"))
        #expect(BackupTarget.isInside(quelle, of: quelle))
    }

    /// Ein Stringvergleich auf Praefixe wuerde hier danebenliegen.
    @Test("Ein gleichnamiger Nachbarordner wird nicht verwechselt")
    func siblingWithSimilarNameIsAllowed() throws {
        let base = try sandbox()
        defer { try? FileManager.default.removeItem(at: base) }
        let quelle = try directory(base.appendingPathComponent("Develop"))
        let ziel = try directory(base.appendingPathComponent("Develop2"))

        #expect(!BackupTarget.isInside(ziel, of: quelle))
    }

    /// APFS unterscheidet standardmaessig keine Gross- und Kleinschreibung.
    @Test("Die Erkennung hängt nicht an der Gross- und Kleinschreibung")
    func detectionIgnoresCase() throws {
        let base = try sandbox()
        defer { try? FileManager.default.removeItem(at: base) }
        let quelle = try directory(base.appendingPathComponent("Develop"))
        _ = try directory(quelle.appendingPathComponent("backups"))

        let anders = base.appendingPathComponent("develop").appendingPathComponent("BACKUPS")
        // Nur pruefen, wenn das Dateisystem wirklich unempfindlich ist.
        if FileManager.default.fileExists(atPath: anders.path) {
            #expect(BackupTarget.isInside(anders, of: quelle))
        }
    }

    /// Ein Symlink im Pfad verdeckt die Verwandtschaft, wenn man Strings vergleicht.
    @Test("Ein Zielordner, der über einen Symlink im Quellordner liegt, wird abgelehnt")
    func symlinkedDestinationIsRejected() throws {
        let base = try sandbox()
        defer { try? FileManager.default.removeItem(at: base) }
        let quelle = try directory(base.appendingPathComponent("Develop"))
        let echt = try directory(quelle.appendingPathComponent("archiv"))
        let verweis = base.appendingPathComponent("abkuerzung")
        try FileManager.default.createSymbolicLink(at: verweis, withDestinationURL: echt)

        #expect(BackupTarget.isInside(verweis, of: quelle))
    }

    @Test("Ein noch nicht angelegter Unterordner der Quelle wird trotzdem erkannt")
    func missingSubdirectoryIsStillDetected() throws {
        let base = try sandbox()
        defer { try? FileManager.default.removeItem(at: base) }
        let quelle = try directory(base.appendingPathComponent("Develop"))

        #expect(BackupTarget.isInside(quelle.appendingPathComponent("gibt-es-noch-nicht"), of: quelle))
    }

    @Test("Ohne Zielordner gibt es eine eigene Meldung")
    func missingDestinationHasItsOwnMessage() throws {
        #expect(throws: BackupTargetError.self) {
            try BackupTarget.validate(destination: "  ", source: "/tmp", requiredBytes: 0)
        }
        #expect(throws: BackupTargetError.self) {
            try BackupTarget.validate(
                destination: "/gibt/es/nicht", source: "/tmp", requiredBytes: 0
            )
        }
    }

    /// Die Rohgroesse ist eine grosszuegige Obergrenze, das Archiv wird kleiner.
    /// Deshalb muss sich die Pruefung uebergehen lassen.
    @Test("Zu wenig Platz lässt sich bewusst übergehen")
    func spaceCheckCanBeOverridden() throws {
        let base = try sandbox()
        defer { try? FileManager.default.removeItem(at: base) }
        let quelle = try directory(base.appendingPathComponent("Develop"))
        let ziel = try directory(base.appendingPathComponent("ziel"))

        #expect(throws: BackupTargetError.self) {
            try BackupTarget.validate(
                destination: ziel.path, source: quelle.path,
                requiredBytes: Int64.max
            )
        }
        try BackupTarget.validate(
            destination: ziel.path, source: quelle.path,
            requiredBytes: Int64.max, ignoreSpace: true
        )
    }

    @Test("Ein Nachbarordner mit genug Platz läuft kommentarlos durch")
    func plainCaseJustWorks() throws {
        let base = try sandbox()
        defer { try? FileManager.default.removeItem(at: base) }
        let quelle = try directory(base.appendingPathComponent("Develop"))
        let ziel = try directory(base.appendingPathComponent("Archive"))

        try BackupTarget.validate(destination: ziel.path, source: quelle.path, requiredBytes: 1024)
    }
}
