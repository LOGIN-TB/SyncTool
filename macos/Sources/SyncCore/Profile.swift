import Foundation

/// Wie sich die App am Ziel anmeldet.
public enum AuthMode: String, Codable, Sendable, CaseIterable {
    case password
    case publicKey
}

/// Ein Sync-Ziel samt lokalem Stammordner.
public struct Profile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String

    /// Lokaler Stammordner, absoluter Pfad ohne abschliessenden Schraegstrich.
    public var localRoot: String

    public var host: String
    /// Hetzner Storage Box hoert auf 23, normale Server auf 22.
    public var port: Int
    public var user: String
    /// Pfad auf dem Ziel. Relativ wird als relativ zum Home des Benutzers gelesen.
    public var remotePath: String

    public var authMode: AuthMode
    public var excludes: [String]

    /// `--delete` laeuft nur, wenn das hier an ist und der Nutzer bestaetigt.
    public var deleteAllowed: Bool
    /// Notbremse: bricht ab, statt mehr als so viele Dateien zu loeschen.
    public var maxDelete: Int

    /// Vergleich per Pruefsumme statt Groesse und Zeitstempel. Langsam, aber gruendlich.
    public var useChecksum: Bool

    /// Leer heisst: automatisch suchen.
    public var rsyncPath: String

    /// Ordner fuer die Backup-Archive. Leer heisst: noch nicht gewaehlt.
    public var backupDestination: String

    /// Rohwert des Transports. Leer heisst: Profil aus einer Fassung vor dem
    /// Anbieterkatalog, also der einzige Weg, den es damals gab.
    public var transportRaw: String

    /// Welche Vorlage das Profil erzeugt hat. Fuer die Oberflaeche und fuer
    /// Sonderfaelle wie das Einrichten eines Schluessels auf einer Storage Box.
    public var providerID: String

    /// SMB-Freigabe, NFS-Export oder die vollstaendige Adresse einer
    /// WebDAV-Ablage. Bei sshRsync und localFolder leer.
    public var share: String

    /// Nach dem Lauf wieder loesen. Gilt nur fuer Einhaengungen, die diese App
    /// selbst vorgenommen hat.
    public var unmountAfterRun: Bool

    /// Kennung, die im Ziel liegt. Wird bei "Verbindung testen" angelegt und
    /// erlaubt es, einen Ordner wiederzuerkennen. Leer heisst: noch keine.
    public var targetMarkerID: String

    /// Wann das Ziel zuletzt vermessen wurde. `nil` heisst: noch nie.
    public var probedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String = "Storage Box",
        localRoot: String = "",
        host: String = "",
        port: Int = 23,
        user: String = "",
        remotePath: String = "dev",
        authMode: AuthMode = .password,
        excludes: [String] = Profile.defaultExcludes,
        deleteAllowed: Bool = false,
        maxDelete: Int = 100,
        useChecksum: Bool = false,
        rsyncPath: String = "",
        backupDestination: String = "",
        transport: Transport = .sshRsync,
        providerID: String = "",
        share: String = "",
        unmountAfterRun: Bool = true,
        targetMarkerID: String = "",
        probedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.localRoot = localRoot
        self.host = host
        self.port = port
        self.user = user
        self.remotePath = remotePath
        self.authMode = authMode
        self.excludes = excludes
        self.deleteAllowed = deleteAllowed
        self.maxDelete = maxDelete
        self.useChecksum = useChecksum
        self.rsyncPath = rsyncPath
        self.backupDestination = backupDestination
        self.transportRaw = transport.raw
        self.providerID = providerID
        self.share = share
        self.unmountAfterRun = unmountAfterRun
        self.targetMarkerID = targetMarkerID
        self.probedAt = probedAt
    }

    /// Von Hand geschrieben, damit eine profiles.json aus einer aelteren
    /// Version weiter gelesen wird.
    ///
    /// Der synthetisierte Decodable wendet die Vorbelegung einer Eigenschaft
    /// NICHT an: ein neues Feld liesse das Dekodieren mit `keyNotFound`
    /// scheitern. `ProfileStore` gaebe daraufhin "keine Profile" zurueck, die
    /// App legte ein leeres an, und das erste Sichern ueberschriebe die echten
    /// Daten. Mit `decodeIfPresent` je Feld ist jedes kuenftige Feld gratis.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Profile()
        // try? liefert T??, das erste ?? flacht ab, das zweite setzt die
        // Vorbelegung ein. Damit ueberlebt das Lesen sowohl ein fehlendes Feld
        // als auch eines mit falschem Typ.
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }

        id = value(.id, UUID())
        name = value(.name, fallback.name)
        localRoot = value(.localRoot, fallback.localRoot)
        host = value(.host, fallback.host)
        port = value(.port, fallback.port)
        user = value(.user, fallback.user)
        remotePath = value(.remotePath, fallback.remotePath)
        authMode = value(.authMode, fallback.authMode)
        excludes = value(.excludes, fallback.excludes)
        deleteAllowed = value(.deleteAllowed, fallback.deleteAllowed)
        maxDelete = value(.maxDelete, fallback.maxDelete)
        useChecksum = value(.useChecksum, fallback.useChecksum)
        rsyncPath = value(.rsyncPath, fallback.rsyncPath)
        backupDestination = value(.backupDestination, fallback.backupDestination)
        // Bewusst ein Literal und nicht fallback.transportRaw: Wenn jemand
        // spaeter die Vorbelegung von Profile() neutral macht, weil es einen
        // Schritt "Anbieter waehlen" gibt, muss ein Altprofil trotzdem
        // sshRsync bleiben.
        transportRaw = value(.transportRaw, "")
        providerID = value(.providerID, "")
        share = value(.share, "")
        unmountAfterRun = value(.unmountAfterRun, true)
        targetMarkerID = value(.targetMarkerID, "")
        // Ohne value(...): die generische Hilfsfunktion machte aus Date? ein
        // Date??, und die Vorbelegung waere dann .some(nil) statt nil.
        probedAt = ((try? container.decodeIfPresent(Date.self, forKey: .probedAt)) ?? nil)
    }

    /// Kommt in kein Archiv, unabhaengig von der Ausschlussliste des Nutzers.
    ///
    /// Getrennt von `defaultExcludes`: Das eine ist eine Entscheidung ueber den
    /// Abgleich, das hier sind Metadaten von Finder und Volume, plus die eigenen
    /// Archive. Ohne die letzten beiden Muster packte das Backup von morgen das
    /// Archiv von heute mit ein, falls es doch einmal im Stammordner landet.
    public static let systemExcludes: [String] = [
        ".DS_Store",
        "._*",
        ".Spotlight-V100/",
        ".fseventsd/",
        ".Trashes/",
        ".TemporaryItems/",
        ".DocumentRevisions-V100/",
        ".vol/",
        "*.zip.part",
        "*-bak-????-??-??*.zip",
        // Die Kennung gehoert zum Ziel und nicht in den Abgleich. Wuerde sie
        // mitwandern, laege auf beiden Seiten dieselbe, und sie koennte zwei
        // Ordner nicht mehr auseinanderhalten.
        ".synctool-ziel",
    ]

    /// `.git/` fehlt hier bewusst: ohne History ist der Abgleich zwischen
    /// Rechnern wertlos.
    public static let defaultExcludes: [String] = [
        ".DS_Store",
        "node_modules/",
        ".venv/",
        "venv/",
        "__pycache__/",
        "target/",
        "build/",
        "dist/",
        ".next/",
        ".turbo/",
        ".gradle/",
        "DerivedData/",
        ".synctool-partial/",
        "*.swp",
        "*.log",
    ]

    /// rsync braucht auf beiden Seiten einen abschliessenden Schraegstrich,
    /// sonst legt es den Ordner im Ziel noch einmal an.
    public var localSource: String {
        let trimmed = localRoot.hasSuffix("/") ? String(localRoot.dropLast()) : localRoot
        return trimmed + "/"
    }

    public var remoteSource: String {
        let path = remotePath.hasSuffix("/") ? String(remotePath.dropLast()) : remotePath
        return "\(user)@\(host):\(path)/"
    }

    /// Kurzfassung des Ziels. Genau das, was man beim Vergleich zweier Profile
    /// sucht, deshalb sieht sie je Transportart anders aus.
    public var summary: String {
        switch transport {
        case .sshRsync:
            let target = [user.isEmpty ? nil : user, host.isEmpty ? nil : host]
                .compactMap { $0 }
                .joined(separator: "@")
            guard !target.isEmpty else { return "Noch nicht eingerichtet" }
            return "\(target):\(port) · \(remotePath.isEmpty ? "—" : remotePath)"
        case .localFolder:
            return remotePath.isEmpty
                ? "Noch nicht eingerichtet" : Format.displayPath(remotePath)
        case .mountedVolume(.webdav):
            guard !share.isEmpty else { return "Noch nicht eingerichtet" }
            return "\(share) · \(remotePath.isEmpty ? "—" : remotePath)"
        case .mountedVolume(let proto):
            guard !host.isEmpty || !share.isEmpty else { return "Noch nicht eingerichtet" }
            return "\(proto.label) //\(host)/\(share) · \(remotePath.isEmpty ? "—" : remotePath)"
        case .unknown(let raw):
            return "Unbekannte Art von Ziel: \(raw)"
        }
    }

    /// Wie die App an dieses Ziel herankommt.
    public var transport: Transport { Transport(raw: transportRaw) }

    /// Ein Profil, dessen Transport diese Fassung nicht kennt, wird angezeigt,
    /// aber niemals ausgefuehrt.
    public var isRunnable: Bool { transport.isRunnable }

    /// Welche Felder dieses Ziel braucht.
    ///
    /// Ueber die Vorlage, damit anbietertypische Beispiele im Formular stehen.
    /// Die Vorlage darf dabei nur Platzhalter aendern, nie eine Pruefregel:
    /// sonst haenge die Vollstaendigkeit eines Profils daran, welche Vorlage
    /// gerade zugeordnet ist.
    public var fields: [FieldDescriptor] {
        ProviderCatalog.preset(for: self)?.fields
            ?? TransportFields.descriptors(for: transport)
    }

    /// Der Wert eines Feldes als Text.
    ///
    /// Damit laufen Pruefung und Formular ueber dieselbe Liste, obwohl `port`
    /// eine Zahl ist und alles andere eine Zeichenkette.
    public func text(for field: ProfileField) -> String {
        switch field {
        case .localRoot: return localRoot
        case .host: return host
        case .user: return user
        case .remotePath: return remotePath
        case .share: return share
        case .port: return String(port)
        }
    }

    /// Derselbe Wert, aber schreibbar.
    ///
    /// Ein Index statt fuenf Schluesselpfaden: das Formular haelt damit eine
    /// Bindung auf `\Profile[text: .host]` und braucht keine Tabelle mehr, die
    /// `ProfileField` auf einen Schluesselpfad abbildet.
    public subscript(text field: ProfileField) -> String {
        get { text(for: field) }
        set {
            switch field {
            case .localRoot: localRoot = newValue
            case .host: host = newValue
            case .user: user = newValue
            case .remotePath: remotePath = newValue
            case .share: share = newValue
            // Eine unlesbare Zahl laesst den alten Wert stehen. Sie zu 0 zu
            // machen hiesse, eine Tippfehler-Zwischenstufe als Mangel zu
            // melden, waehrend der Nutzer noch tippt.
            case .port: port = Int(newValue) ?? port
            }
        }
    }

    /// Mangel ohne Dateisystemzugriff.
    ///
    /// Wird je Zeile der Profilliste und je Tastendruck gerufen. Ein
    /// `fileExists` auf einem eingehaengten Netzlaufwerk wuerde die Oberflaeche
    /// dabei anhalten, deshalb prueft das hier nur, ob ueberhaupt etwas
    /// eingetragen ist.
    public func issues() -> [ProfileIssue] {
        // Ein unbekannter Transport ist der einzige Mangel, der zaehlt: was die
        // anderen Felder enthalten, kann diese Fassung nicht beurteilen.
        if case .unknown(let raw) = transport {
            return [
                ProfileIssue(
                    field: .host,
                    message: "Dieses Profil kommt aus einer neueren Version von SyncTool "
                        + "(\(raw)) und lässt sich hier nicht ausführen."
                )
            ]
        }
        return fields.compactMap { $0.issue(in: self) }
    }

    public var isComplete: Bool { issues().isEmpty }

    /// Getrennt, weil sie das Dateisystem befragt. Nur fuer das gerade
    /// bearbeitete Profil aufrufen, nie fuer die ganze Liste.
    public func localRootIssue(fileManager: FileManager = .default) -> ProfileIssue? {
        guard !localRoot.isEmpty else {
            return ProfileIssue(field: .localRoot, message: "Kein lokaler Ordner gewählt.")
        }
        guard !fileManager.fileExists(atPath: localRoot) else { return nil }
        return ProfileIssue(
            field: .localRoot, message: "Lokaler Ordner existiert nicht: \(localRoot)"
        )
    }

    /// Der Zielordner eines lokalen Ziels muss vorher da sein.
    ///
    /// Sonst legt rsync ihn beim Hochladen einfach an, und genau das ist der
    /// gefaehrliche Fall: ist die Platte nicht angesteckt, entsteht
    /// `/Volumes/Backup/Develop` als Ordner auf der Startplatte, und der naechste
    /// Lauf vergleicht gegen einen leeren Ordner.
    public func targetFolderIssue(fileManager: FileManager = .default) -> ProfileIssue? {
        guard case .localFolder = transport else { return nil }
        guard !remotePath.isEmpty else {
            return ProfileIssue(field: .remotePath, message: "Kein Zielordner gewählt.")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: remotePath, isDirectory: &isDirectory) else {
            return ProfileIssue(
                field: .remotePath,
                message: "Der Zielordner \(remotePath) ist nicht da. Bei einem Laufwerk heißt "
                    + "das meistens, dass es nicht verbunden ist."
            )
        }
        guard isDirectory.boolValue else {
            return ProfileIssue(
                field: .remotePath, message: "\(remotePath) ist eine Datei und kein Ordner."
            )
        }
        return nil
    }

    /// Fehlerliste fuer das UI. Leer heisst: benutzbar.
    public func validationErrors() -> [String] {
        var problems = issues().filter { $0.field != .localRoot }.map(\.message)
        if let target = targetFolderIssue() {
            // Der reine Teil hat den Pfad schon als "vorhanden" abgehakt, hier
            // kommt die Aussage ueber das Dateisystem dazu.
            problems.removeAll { $0 == "Kein Zielordner gewählt." }
            problems.append(target.message)
        }
        if let root = localRootIssue() { problems.insert(root.message, at: 0) }
        return problems
    }

    /// Kopie mit neuer Kennung.
    ///
    /// Der Schluesselbundeintrag wird nicht mitkopiert und muss es auch nicht:
    /// er haengt an Server, Port und Benutzer, die das Duplikat unveraendert
    /// uebernimmt. Wer einen davon aendert, steht danach ohne Passwort da, und
    /// das ist richtig so.
    public func duplicated(named name: String) -> Profile {
        var copy = self
        copy.id = UUID()
        copy.name = name
        return copy
    }
}

/// Ein Feld, an dem ein Mangel haengt.
///
/// Ohne diese Zuordnung liesse sich eine Meldung nicht an das Eingabefeld
/// haengen, das sie meint, und ein Aufrufer muesste sie an ihrem Wortlaut
/// erkennen.
public enum ProfileField: String, Sendable, CaseIterable {
    case localRoot, host, user, remotePath, port, share

    /// Nur ein Rueckfall fuer Meldungen ohne Deskriptor. Die Beschriftung im
    /// Formular kommt aus `FieldDescriptor.label`, weil dasselbe Feld je
    /// Transportart anders heisst: "Ordner auf dem Server" bei ssh,
    /// "Ordner in der Freigabe" bei SMB.
    public var label: String {
        switch self {
        case .localRoot: return "Stammordner"
        case .host: return "Server"
        case .user: return "Benutzer"
        case .remotePath: return "Ordner auf dem Server"
        case .port: return "Port"
        case .share: return "Freigabe"
        }
    }
}

public struct ProfileIssue: Hashable, Sendable {
    public let field: ProfileField
    public let message: String

    public init(field: ProfileField, message: String) {
        self.field = field
        self.message = message
    }
}
