import Foundation

/// Eine Pruefregel fuer ein einzelnes Eingabefeld.
///
/// Rein, ohne Dateisystem und ohne Netz. Genau die Form, die `Profile.issues()`
/// braucht: die Funktion laeuft je Zeile der Profilliste und je Tastendruck.
public enum ValidationRule: String, Sendable, Hashable {
    case nonEmpty
    case portRange
    case hostname
    case absolutePath
    case davURL
    case shareName
    /// Darf leer bleiben.
    case optional

    /// `missing` ist der Satz des Feldes fuer "noch nichts eingetragen". Er
    /// steht im Deskriptor und nicht hier, damit jedes Feld in seiner eigenen
    /// Sprache meldet: "Kein Server angegeben." und nicht "Fehlt noch."
    public func check(_ value: String, missing: String) -> String? {
        if value.isEmpty {
            return self == .optional ? nil : missing
        }
        switch self {
        case .nonEmpty, .optional:
            return nil
        case .portRange:
            guard let port = Int(value), (1...65_535).contains(port) else {
                return "Port liegt außerhalb von 1–65535."
            }
            return nil
        case .hostname:
            // Der haeufigste Tippfehler, sobald "Adresse" und WebDAV
            // nebeneinander im Formular stehen.
            if value.contains("://") { return "Nur den Servernamen, ohne https:// davor." }
            if value.contains("/") { return "Nur den Servernamen, ohne Pfad dahinter." }
            return nil
        case .absolutePath:
            return value.hasPrefix("/") ? nil : "Muss mit / anfangen."
        case .davURL:
            guard value.hasPrefix("https://") else {
                return "Muss mit https:// anfangen. Ohne Verschlüsselung ginge das Passwort "
                    + "im Klartext über die Leitung."
            }
            return URL(string: value) == nil ? "Das ist keine gültige Adresse." : nil
        case .shareName:
            return value.contains("/") ? "Nur der Name der Freigabe, ohne Pfad." : nil
        }
    }
}

/// Ein Feld, wie es im Formular steht und wie es geprueft wird.
///
/// Eine Beschreibung statt einer Sonderbehandlung je Transportart: welche
/// Felder ein Ziel braucht, steht damit an genau einer Stelle, und `issues()`
/// sowie das Formular lesen dieselbe Liste.
public struct FieldDescriptor: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case text
        case secret
        case integer
        case folderPicker(message: String)
    }

    public var id: ProfileField { field }
    public let field: ProfileField
    public let label: String
    /// Ein echtes Beispiel, kein "Bitte eintragen". Der Platzhalter ist die
    /// wirksamste Anleitung in einem Formular.
    public let prompt: String
    public let help: String?
    public let kind: Kind
    public let rule: ValidationRule
    /// Meldung, wenn das Feld leer ist.
    public let missing: String

    public init(
        field: ProfileField,
        label: String,
        prompt: String = "",
        help: String? = nil,
        kind: Kind = .text,
        rule: ValidationRule,
        missing: String
    ) {
        self.field = field
        self.label = label
        self.prompt = prompt
        self.help = help
        self.kind = kind
        self.rule = rule
        self.missing = missing
    }

    /// Dieselbe Regel, anderer Platzhalter.
    ///
    /// Nur der Platzhalter, nichts sonst: eine Vorlage darf ein Beispiel
    /// mitbringen, aber nicht die Pruefung verschieben.
    public func with(prompt: String) -> FieldDescriptor {
        FieldDescriptor(
            field: field, label: label, prompt: prompt, help: help, kind: kind, rule: rule,
            missing: missing
        )
    }

    /// `nil` heisst: in Ordnung.
    public func issue(in profile: Profile) -> ProfileIssue? {
        guard let message = rule.check(profile.text(for: field), missing: missing) else {
            return nil
        }
        return ProfileIssue(field: field, message: message)
    }
}

/// Welche Felder eine Transportart braucht.
///
/// Der Satz fuer `sshRsync` erzeugt buchstabengleich die Meldungen, die die App
/// vorher fest verdrahtet hatte. Alles andere waere eine Verhaltensaenderung,
/// die sich als Aufraeumarbeit tarnt.
public enum TransportFields {
    public static func descriptors(for transport: Transport) -> [FieldDescriptor] {
        switch transport {
        case .sshRsync:
            return [
                localRoot,
                host(prompt: "server.example.com"),
                user(prompt: "benutzername"),
                remotePathOnServer,
                port,
            ]
        case .localFolder:
            return [localRoot, targetFolder]
        case .mountedVolume(.webdav):
            return [localRoot, davURL, user(prompt: "benutzername"), remotePathInShare]
        case .mountedVolume(.nfs):
            // Ein NFS-Export ist ein Pfad, keine Freigabe: `/volume1/backup`.
            // Mit der Regel fuer Freigabennamen waere jeder richtige Wert ein
            // Mangel, weil er einen Schraegstrich enthaelt.
            return [localRoot, host(prompt: "server.example.com"), nfsExport, remotePathInShare]
        case .mountedVolume(.smb), .mountedVolume(.afp):
            return [
                localRoot,
                host(prompt: "server.example.com"),
                smbShare,
                user(prompt: "benutzername"),
                remotePathInShare,
                port,
            ]
        case .unknown:
            return [localRoot]
        }
    }

    // MARK: - Die einzelnen Felder

    /// Die Platzhalter hier sind generisch. Ein anbietertypisches Beispiel wie
    /// `u123456.your-storagebox.de` gehoert in die Vorlage, die es meint, und
    /// nicht in die Transportart: unter "SMB-Freigabe" waere es eine falsche
    /// Spur.
    static let localRoot = FieldDescriptor(
        field: .localRoot,
        label: "Stammordner",
        kind: .folderPicker(message: "Ordner auf diesem Rechner wählen"),
        rule: .nonEmpty,
        missing: "Kein lokaler Ordner gewählt."
    )

    static func host(prompt: String) -> FieldDescriptor {
        FieldDescriptor(
            field: .host,
            label: "Server",
            prompt: prompt,
            rule: .hostname,
            missing: "Kein Server angegeben."
        )
    }

    static func user(prompt: String) -> FieldDescriptor {
        FieldDescriptor(
            field: .user,
            label: "Benutzer",
            prompt: prompt,
            rule: .nonEmpty,
            missing: "Kein Benutzer angegeben."
        )
    }

    static let port = FieldDescriptor(
        field: .port,
        label: "Port",
        kind: .integer,
        rule: .portRange,
        missing: "Kein Port angegeben."
    )

    static let remotePathOnServer = FieldDescriptor(
        field: .remotePath,
        label: "Ordner auf dem Server",
        prompt: "projekte",
        help: "Ein relativer Pfad zählt ab dem Heimatverzeichnis.",
        rule: .nonEmpty,
        missing: "Kein Pfad auf dem Server angegeben."
    )

    static let remotePathInShare = FieldDescriptor(
        field: .remotePath,
        label: "Ordner in der Freigabe",
        prompt: "projekte",
        help: "Zählt ab dem Stamm der Freigabe. Leer heißt: die Freigabe selbst.",
        rule: .optional,
        missing: "Kein Pfad in der Freigabe angegeben."
    )

    static let smbShare = FieldDescriptor(
        field: .share,
        label: "Freigabe",
        prompt: "freigabename",
        help: "Der Name, den der Server anbietet, ohne Pfad dahinter.",
        rule: .shareName,
        missing: "Keine Freigabe angegeben."
    )

    static let nfsExport = FieldDescriptor(
        field: .share,
        label: "Export",
        prompt: "/export/daten",
        help: "Der Pfad, den der Server exportiert. Er steht in der "
            + "NFS-Konfiguration des Servers.",
        rule: .absolutePath,
        missing: "Kein Export angegeben."
    )

    static let davURL = FieldDescriptor(
        field: .share,
        label: "Adresse der Ablage",
        prompt: "https://server.example.com/remote.php/dav/files/benutzername",
        help: "Die vollständige WebDAV-Adresse. Sie steht bei jedem Anbieter an einer "
            + "anderen Stelle, deshalb lässt sie sich nicht aus dem Servernamen ableiten.",
        rule: .davURL,
        missing: "Keine Adresse angegeben."
    )

    static let targetFolder = FieldDescriptor(
        field: .remotePath,
        label: "Zielordner",
        prompt: "/Volumes/Sicherung/Projekte",
        help: "Der Ordner, mit dem abgeglichen wird. Bei Google Drive, OneDrive oder "
            + "Dropbox ist das der Ordner, den der Anbieter selbst angelegt hat.",
        kind: .folderPicker(message: "Zielordner wählen"),
        rule: .absolutePath,
        missing: "Kein Zielordner gewählt."
    )
}
