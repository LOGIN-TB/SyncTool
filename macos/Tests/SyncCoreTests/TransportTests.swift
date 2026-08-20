import Foundation
import Testing

@testable import SyncCore

@Suite("Transportarten")
struct TransportTests {

    // MARK: - Rohwerte

    @Test("Jede bekannte Art übersteht den Umweg über den Rohwert")
    func knownTransportsRoundTrip() {
        let all: [Transport] = [.sshRsync, .localFolder]
            + VolumeProtocol.allCases.map { Transport.mountedVolume($0) }
        for transport in all {
            #expect(Transport(raw: transport.raw) == transport, "\(transport)")
        }
    }

    /// Der Grund, warum der Rohwert gespeichert wird und nicht das Enum: ein
    /// Profil aus einer neueren Fassung darf nicht stillschweigend zu einem
    /// Storage-Box-Profil werden.
    @Test("Ein unbekannter Rohwert bleibt erhalten")
    func unknownRawSurvives() {
        let transport = Transport(raw: "rclone:onedrive")
        #expect(transport == .unknown("rclone:onedrive"))
        #expect(transport.raw == "rclone:onedrive")
        #expect(!transport.isRunnable)
    }

    @Test("Ein leerer Rohwert ist der Weg, den es früher als einzigen gab")
    func emptyRawIsSSH() {
        #expect(Transport(raw: "") == .sshRsync)
    }

    @Test("Ein Mount mit unbekanntem Protokoll ist unbekannt, nicht SMB")
    func unknownVolumeProtocolIsUnknown() {
        #expect(Transport(raw: "mount:ftp") == .unknown("mount:ftp"))
    }

    // MARK: - Eigenschaften

    @Test("Nur ssh braucht eine Gegenstelle hinter -e")
    func onlySSHUsesRemoteShell() {
        #expect(Transport.sshRsync.usesRemoteShell)
        #expect(!Transport.localFolder.usesRemoteShell)
        #expect(!Transport.mountedVolume(.smb).usesRemoteShell)
        #expect(!Transport.unknown("x").usesRemoteShell)
    }

    /// NFS entscheidet anhand der Adresse des Rechners. Ein Passwortfeld waere
    /// eine Luege.
    @Test("NFS und lokale Ordner brauchen keine Anmeldung")
    func credentialsWhereTheyMakeSense() {
        #expect(Transport.sshRsync.needsCredentials)
        #expect(Transport.mountedVolume(.smb).needsCredentials)
        #expect(Transport.mountedVolume(.webdav).needsCredentials)
        #expect(!Transport.mountedVolume(.nfs).needsCredentials)
        #expect(!Transport.localFolder.needsCredentials)
    }

    @Test("Jedes Protokoll kennt seinen Dateisystemnamen")
    func fsTypeNames() {
        #expect(VolumeProtocol.smb.fsTypeName == "smbfs")
        #expect(VolumeProtocol.nfs.fsTypeName == "nfs")
        #expect(VolumeProtocol.webdav.fsTypeName == "webdav")
        #expect(VolumeProtocol.afp.fsTypeName == "afpfs")
    }
}

@Suite("Feld-Deskriptoren")
struct FieldDescriptorTests {

    // MARK: - Welche Felder welches Ziel braucht

    /// Der Satz fuer ssh muss buchstabengleich die Meldungen erzeugen, die die
    /// App vorher fest verdrahtet hatte. Sonst waere der Umbau eine
    /// Verhaltensaenderung, die sich als Aufraeumarbeit tarnt.
    @Test("Der ssh-Satz meldet genau die alten Sätze")
    func sshMessagesAreUnchanged() {
        let empty = Profile(localRoot: "", host: "", port: 0, user: "", remotePath: "")
        var messages: [ProfileField: String] = [:]
        for issue in empty.issues() { messages[issue.field] = issue.message }
        #expect(messages[.localRoot] == "Kein lokaler Ordner gewählt.")
        #expect(messages[.host] == "Kein Server angegeben.")
        #expect(messages[.user] == "Kein Benutzer angegeben.")
        #expect(messages[.remotePath] == "Kein Pfad auf dem Server angegeben.")
        #expect(messages[.port] == "Port liegt außerhalb von 1–65535.")
    }

    @Test("Ein lokaler Ordner fragt nicht nach Server, Benutzer und Port")
    func localFolderAsksLess() {
        let profile = Profile(localRoot: "/tmp", transport: .localFolder)
        let fields = Set(profile.fields.map(\.field))
        #expect(fields == [.localRoot, .remotePath])
        // Der Port steht im Profil weiterhin auf 23. Ohne die Beschraenkung auf
        // die Felder dieses Ziels wuerde er trotzdem geprueft.
        #expect(!profile.issues().contains { $0.field == .port })
    }

    @Test("NFS fragt nicht nach einem Benutzer, SMB schon")
    func nfsAsksNoUser() {
        let nfs = Profile(transport: .mountedVolume(.nfs)).fields.map(\.field)
        let smb = Profile(transport: .mountedVolume(.smb)).fields.map(\.field)
        #expect(!nfs.contains(.user))
        #expect(smb.contains(.user))
        #expect(nfs.contains(.share))
    }

    @Test("WebDAV fragt nach einer Adresse statt nach einem Servernamen")
    func webdavAsksForAURL() {
        let fields = Profile(transport: .mountedVolume(.webdav)).fields.map(\.field)
        #expect(fields.contains(.share))
        #expect(!fields.contains(.host))
        #expect(!fields.contains(.port))
    }

    /// Ein Profil aus einer neueren Fassung wird angezeigt, laeuft aber nie,
    /// und der Grund steht als Satz da statt als Feldsalat.
    @Test("Ein unbekannter Transport meldet genau einen Mangel")
    func unknownTransportReportsOnce() {
        var profile = Profile(localRoot: "/tmp", host: "h", user: "u", remotePath: "dev")
        profile.transportRaw = "rclone:s3"
        let issues = profile.issues()
        #expect(issues.count == 1)
        #expect(issues.first?.message.contains("rclone:s3") == true)
        #expect(!profile.isRunnable)
        #expect(!profile.isComplete)
    }

    /// Die Transportart gilt fuer alle ihre Anbieter, also darf ihr Beispiel
    /// keinen davon nennen. Ein `u123456.your-storagebox.de` unter
    /// "SMB-Freigabe" waere eine falsche Spur.
    @Test("Die Platzhalter der Transportart nennen keinen Anbieter und keine Person")
    func transportPromptsAreGeneric() {
        // "holger", "erbe" und "login-online" stehen hier absichtlich: es ist der
        // Name des Autors, und genau der darf nie als Beispiel in der
        // Oberflaeche landen. Wer die Eintraege entfernt, weil sie nach einem
        // Datenleck aussehen, entfernt die Pruefung.
        let verboten = [
            "storagebox", "hetzner", "fritz", "synology", "magenta",  // Anbieter
            "holger", "erbe", "login-online",  // Autor
        ]
        for transport: Transport in [
            .sshRsync, .localFolder, .mountedVolume(.smb), .mountedVolume(.nfs),
            .mountedVolume(.webdav), .mountedVolume(.afp),
        ] {
            for field in TransportFields.descriptors(for: transport) {
                let text = (field.prompt + " " + (field.help ?? "")).lowercased()
                for wort in verboten {
                    #expect(!text.contains(wort), "\(transport)/\(field.field): \(wort)")
                }
            }
        }
    }

    /// Ein anbietertypisches Beispiel steht in der Vorlage, die es meint.
    @Test("Die Vorlage darf ein eigenes Beispiel mitbringen")
    func presetMayOverridePrompts() throws {
        let box = try #require(ProviderCatalog.preset(id: "hetzner-storagebox"))
        let host = try #require(box.fields.first { $0.field == .host })
        #expect(host.prompt == "u123456.your-storagebox.de")
        // Dieselbe Transportart, ohne eigenes Beispiel: generisch.
        let server = try #require(ProviderCatalog.preset(id: "ssh-server"))
        #expect(server.fields.first { $0.field == .host }?.prompt == "server.example.com")
    }

    /// Sonst haenge die Vollstaendigkeit eines Profils daran, welche Vorlage
    /// gerade zugeordnet ist.
    @Test("Eine Vorlage ändert nur Platzhalter, keine Prüfregel")
    func presetNeverChangesRules() {
        for preset in ProviderCatalog.presets(rcloneAvailable: true) {
            let base = TransportFields.descriptors(for: preset.transport)
            #expect(preset.fields.map(\.field) == base.map(\.field), "\(preset.id)")
            #expect(preset.fields.map(\.rule) == base.map(\.rule), "\(preset.id)")
            #expect(preset.fields.map(\.missing) == base.map(\.missing), "\(preset.id)")
        }
    }

    /// Der gemeldete Fehler: der NFS-Export lief unter der Regel fuer
    /// Freigabennamen, und die lehnt jeden Schraegstrich ab. Damit war jeder
    /// richtige Wert ein Mangel.
    @Test("Ein NFS-Export darf ein Pfad sein, eine SMB-Freigabe nicht")
    func nfsExportIsAPathAndSMBShareIsNot() {
        var nfs = Profile(host: "nas.fritz.box", transport: .mountedVolume(.nfs))
        nfs.localRoot = "/tmp"
        nfs.share = "/volume1/backup"
        #expect(!nfs.issues().contains { $0.field == .share })

        nfs.share = "volume1"
        #expect(nfs.issues().contains { $0.field == .share })

        var smb = Profile(host: "nas.fritz.box", user: "benutzer", transport: .mountedVolume(.smb))
        smb.localRoot = "/tmp"
        smb.share = "backup"
        #expect(!smb.issues().contains { $0.field == .share })

        smb.share = "backup/projekte"
        #expect(smb.issues().contains { $0.field == .share })
    }

    /// Ein leerer Pfad in der Freigabe heisst: die Freigabe selbst. Das ist ein
    /// gueltiges Ziel und darf kein Mangel sein.
    @Test("Der Ordner in der Freigabe darf leer bleiben")
    func pathInShareMayBeEmpty() {
        var profile = Profile(
            localRoot: "/tmp", host: "nas.fritz.box", user: "benutzer", remotePath: "",
            transport: .mountedVolume(.smb)
        )
        profile.share = "backup"
        #expect(profile.issues().isEmpty)
    }

    // MARK: - Der Wert eines Feldes als Text

    @Test("Lesen und Schreiben über das Feld trifft dieselbe Eigenschaft")
    func textSubscriptRoundTrips() {
        var profile = Profile()
        profile[text: .host] = "box.example.org"
        profile[text: .share] = "backup"
        profile[text: .port] = "22"
        #expect(profile.host == "box.example.org")
        #expect(profile.share == "backup")
        #expect(profile.port == 22)
        #expect(profile.text(for: .port) == "22")
    }

    /// Waehrend des Tippens ist ein Portfeld voruebergehend leer. Den Wert dann
    /// auf 0 zu setzen hiesse, dem Nutzer beim Tippen einen Mangel zu melden.
    @Test("Eine unlesbare Portzahl lässt den alten Wert stehen")
    func unreadablePortKeepsTheOldValue() {
        var profile = Profile(port: 23)
        profile[text: .port] = ""
        #expect(profile.port == 23)
        profile[text: .port] = "zwei"
        #expect(profile.port == 23)
    }
}

@Suite("Prüfregeln für Eingabefelder")
struct ValidationRuleTests {

    @Test("Ein leeres Feld meldet den Satz des Feldes, nicht den der Regel")
    func emptyUsesTheFieldsOwnSentence() {
        #expect(ValidationRule.hostname.check("", missing: "Kein Server angegeben.")
            == "Kein Server angegeben.")
        #expect(ValidationRule.optional.check("", missing: "egal") == nil)
    }

    /// Der haeufigste Tippfehler, sobald "Adresse" und WebDAV nebeneinander im
    /// Formular stehen. "Kein Server angegeben." bei ausgefuelltem Feld waere
    /// die schlechteste denkbare Antwort darauf.
    @Test("Ein Servername mit https:// davor wird als solcher gemeldet")
    func hostnameWithSchemeIsNamed() {
        let message = ValidationRule.hostname.check("https://box.example.org", missing: "x")
        #expect(message == "Nur den Servernamen, ohne https:// davor.")
    }

    @Test("Ein Servername mit Pfad dahinter wird als solcher gemeldet")
    func hostnameWithPathIsNamed() {
        #expect(
            ValidationRule.hostname.check("box.example.org/dev", missing: "x")
                == "Nur den Servernamen, ohne Pfad dahinter."
        )
        #expect(ValidationRule.hostname.check("box.example.org", missing: "x") == nil)
    }

    @Test("Der Port muss zwischen 1 und 65535 liegen")
    func portRange() {
        for value in ["0", "70000", "-1", "zwei"] {
            #expect(ValidationRule.portRange.check(value, missing: "x") != nil, "\(value)")
        }
        for value in ["1", "22", "23", "65535"] {
            #expect(ValidationRule.portRange.check(value, missing: "x") == nil, "\(value)")
        }
    }

    @Test("Ein WebDAV-Ziel ohne https wird abgelehnt")
    func davNeedsHTTPS() {
        let message = ValidationRule.davURL.check("http://cloud.example.org", missing: "x")
        #expect(message?.contains("https://") == true)
        #expect(ValidationRule.davURL.check("https://cloud.example.org/dav", missing: "x") == nil)
    }

    @Test("Eine Freigabe ist ein Name und kein Pfad")
    func shareIsAName() {
        #expect(ValidationRule.shareName.check("backup/dev", missing: "x") != nil)
        #expect(ValidationRule.shareName.check("backup", missing: "x") == nil)
    }

    @Test("Ein Zielordner muss absolut sein")
    func absolutePath() {
        #expect(ValidationRule.absolutePath.check("Develop", missing: "x") != nil)
        #expect(ValidationRule.absolutePath.check("/Volumes/Backup", missing: "x") == nil)
    }
}
