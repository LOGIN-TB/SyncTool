import Foundation
import Testing

@testable import SyncCore

@Suite("Endpunkte und Flag-Politik")
struct SyncEndpointsTests {

    // MARK: - Endpunkte

    @Test("Bei ssh bleibt es bei benutzer@server:ordner")
    func sshEndpointsUnchanged() {
        let profile = Profile(
            localRoot: "/Users/test/Develop", host: "u1.your-storagebox.de", user: "u1",
            remotePath: "dev"
        )
        let ends = SyncEndpoints.resolve(profile: profile)
        #expect(ends.local == "/Users/test/Develop/")
        #expect(ends.remote == "u1@u1.your-storagebox.de:dev/")
    }

    @Test("Ein lokaler Ordner ist einfach der Pfad")
    func localFolderEndpoints() {
        let profile = Profile(
            localRoot: "/Users/test/Develop",
            remotePath: "/Volumes/Backup/Develop",
            transport: .localFolder
        )
        let ends = SyncEndpoints.resolve(profile: profile)
        #expect(ends.local == "/Users/test/Develop/")
        #expect(ends.remote == "/Volumes/Backup/Develop/")
    }

    /// rsync braucht auf beiden Seiten einen Schraegstrich, sonst legt es den
    /// Ordner im Ziel noch einmal an. Ein doppelter waere ebenso falsch.
    @Test("Ein schon vorhandener Schrägstrich wird nicht verdoppelt")
    func trailingSlashIsNormalised() {
        let profile = Profile(
            localRoot: "/Users/test/Develop/", remotePath: "/Volumes/Backup/",
            transport: .localFolder
        )
        let ends = SyncEndpoints.resolve(profile: profile)
        #expect(ends.local == "/Users/test/Develop/")
        #expect(ends.remote == "/Volumes/Backup/")
    }

    /// Absolut waere falsch: dieselbe Freigabe an einer anderen Stelle im
    /// Dateisystem meinte dann einen anderen Ordner.
    @Test("Bei einer Freigabe zählt der Pfad ab dem Einhängepunkt")
    func mountedVolumeJoinsUnderTheMountPoint() {
        let profile = Profile(
            localRoot: "/Users/test/Develop", host: "nas.local", remotePath: "projekte",
            transport: .mountedVolume(.smb), share: "backup"
        )
        let ends = SyncEndpoints.resolve(
            profile: profile, mountPoint: "/private/tmp/synctool-mount/backup"
        )
        #expect(ends.remote == "/private/tmp/synctool-mount/backup/projekte/")
    }

    @Test("Ohne Pfad in der Freigabe ist der Einhängepunkt selbst das Ziel")
    func mountedVolumeWithoutSubpath() {
        let profile = Profile(
            localRoot: "/Users/test/Develop", host: "nas.local", remotePath: "",
            transport: .mountedVolume(.smb), share: "backup"
        )
        let ends = SyncEndpoints.resolve(profile: profile, mountPoint: "/private/tmp/m")
        #expect(ends.remote == "/private/tmp/m/")
    }

    /// Ein Profil aus einer neueren Fassung laeuft nie, aber die Endpunkte
    /// duerfen nicht in eine Sonderbehandlung laufen.
    @Test("Ein unbekannter Transport verhält sich wie ssh")
    func unknownFallsBackToSSH() {
        var profile = Profile(host: "h", user: "u", remotePath: "dev")
        profile.transportRaw = "rclone:s3"
        #expect(SyncEndpoints.resolve(profile: profile).remote == "u@h:dev/")
    }

    // MARK: - Flag-Politik

    /// Golden-Test. Der Umbau von einer Konstante auf einen Wert darf die
    /// bestehende Zeile nicht um ein Zeichen verschieben.
    @Test("Die ssh-Flags stehen fest")
    func sshFlavourIsFrozen() {
        #expect(RsyncFlavour.sshRsync.baseFlags == ["-rlptz"])
        #expect(RsyncFlavour.sshRsync.usesRemoteShell)
        #expect(RsyncFlavour.forTransport(.sshRsync) == .sshRsync)
    }

    /// `-z` komprimiert bei einem Lauf im Dateisystem nur die Luft.
    @Test("Ein lokaler Lauf komprimiert nicht und braucht keine Shell")
    func localFlavour() {
        #expect(RsyncFlavour.local.baseFlags == ["-rlpt"])
        #expect(!RsyncFlavour.local.usesRemoteShell)
        #expect(RsyncFlavour.forTransport(.localFolder) == .local)
        #expect(RsyncFlavour.forTransport(.mountedVolume(.smb)) == .local)
    }

    @Test("Ohne Gegenstelle steht kein -e in der Zeile")
    func noRemoteShellArgumentForLocalRuns() {
        let profile = Profile(
            localRoot: "/Users/test/Develop", remotePath: "/Volumes/Backup",
            transport: .localFolder
        )
        let args = RsyncArguments.arguments(
            profile: profile,
            direction: .push,
            options: .init(
                dryRun: false, includeDeletes: false, remoteShell: "/tmp/rsh",
                endpoints: SyncEndpoints.resolve(profile: profile),
                flavour: .forTransport(profile.transport)
            )
        )
        #expect(!args.contains("-e"))
        #expect(!args.contains("/tmp/rsh"))
        #expect(args.first == "-rlpt")
        #expect(args.suffix(2) == ["/Users/test/Develop/", "/Volumes/Backup/"])
    }

    @Test("Mit Gegenstelle steht -e weiterhin drin")
    func remoteShellStaysForSSH() {
        let profile = Profile(localRoot: "/x", host: "h", user: "u", remotePath: "dev")
        let args = RsyncArguments.arguments(
            profile: profile,
            direction: .push,
            options: .init(dryRun: false, includeDeletes: false, remoteShell: "/tmp/rsh")
        )
        #expect(args.contains("-e"))
        #expect(args.contains("/tmp/rsh"))
        #expect(args.first == "-rlptz")
    }

    @Test("Der Bestandslauf nimmt die Endpunkte, die er bekommt")
    func inventoryUsesEndpoints() {
        let profile = Profile(
            localRoot: "/Users/test/Develop", remotePath: "/Volumes/Backup",
            transport: .localFolder
        )
        let ends = SyncEndpoints.resolve(profile: profile)
        let args = RsyncArguments.inventoryArguments(
            profile: profile,
            options: .init(side: .remote, emptyDirectory: "/tmp/leer", endpoints: ends)
        )
        #expect(args.contains("/Volumes/Backup/"))
        #expect(!args.contains("-e"))
    }
}
