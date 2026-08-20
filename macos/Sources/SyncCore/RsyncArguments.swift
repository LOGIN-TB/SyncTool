import Foundation

public enum SyncDirection: String, Sendable, CaseIterable {
    /// Vom Server auf diesen Rechner.
    case pull
    /// Von diesem Rechner auf den Server.
    case push

    public var label: String {
        switch self {
        case .pull: return "Herunterladen"
        case .push: return "Hochladen"
        }
    }
}

public struct RsyncPlan: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]

    /// Kommandozeile fuer das Protokoll. Das Passwort taucht darin nicht auf,
    /// es laeuft ueber den Socket.
    public var displayCommand: String { processPlan.displayCommand }

    public var processPlan: ProcessPlan {
        ProcessPlan(executable: executable, arguments: arguments, environment: environment)
    }
}

public enum RsyncArguments {
    public struct Options: Sendable {
        public var dryRun: Bool
        public var includeDeletes: Bool
        public var remoteShell: String
        public var excludeFile: String?
        /// Datei mit `P`-Regeln. Schuetzt Dateien der Empfaengerseite davor,
        /// von `--delete` weggeraeumt zu werden.
        public var protectFile: String?
        /// `nil` heisst: auf dem alten Weg aus dem Profil ableiten. So bleibt
        /// jeder vorhandene Aufruf gueltig.
        public var endpoints: SyncEndpoints?
        public var flavour: RsyncFlavour

        public init(
            dryRun: Bool,
            includeDeletes: Bool,
            remoteShell: String,
            excludeFile: String? = nil,
            protectFile: String? = nil,
            endpoints: SyncEndpoints? = nil,
            flavour: RsyncFlavour = .sshRsync
        ) {
            self.dryRun = dryRun
            self.includeDeletes = includeDeletes
            self.remoteShell = remoteShell
            self.excludeFile = excludeFile
            self.protectFile = protectFile
            self.endpoints = endpoints
            self.flavour = flavour
        }
    }

    public static func arguments(
        profile: Profile,
        direction: SyncDirection,
        options: Options
    ) -> [String] {
        var args = options.flavour.baseFlags
        args += [
            "--itemize-changes",
            "--out-format=\(ItemizeParser.outFormat)",
            "--modify-window=1",
        ]

        if profile.useChecksum { args.append("--checksum") }
        // Schutzregeln vor die Ausschluesse: bei rsync gewinnt die erste
        // passende Regel.
        if let protectFile = options.protectFile, options.includeDeletes, profile.deleteAllowed {
            args.append("--filter=merge \(protectFile)")
        }
        if let excludeFile = options.excludeFile { args.append("--exclude-from=\(excludeFile)") }

        // Ohne Gegenstelle kein `-e`. Ein lokaler Lauf braucht keine Shell,
        // und rsync wuerde die Angabe als Fehler auslegen.
        if options.flavour.usesRemoteShell { args += ["-e", options.remoteShell] }

        if options.dryRun {
            args.append("--dry-run")
        } else {
            args += ["--partial", "--partial-dir=.synctool-partial", "--stats"]
        }

        // Loeschen laeuft nie beilaeufig mit: der Aufrufer muss es anfordern,
        // und das Profil muss es erlauben.
        if options.includeDeletes && profile.deleteAllowed {
            args.append("--delete")
            // Bricht ab, statt mehr zu loeschen. Die Vorschau kommt aus den
            // Bestaenden, dieser Lauf hier ist immer der echte.
            args.append("--max-delete=\(profile.maxDelete)")
        }

        let ends = options.endpoints ?? SyncEndpoints.resolve(profile: profile)
        switch direction {
        case .pull:
            args += [ends.remote, ends.local]
        case .push:
            args += [ends.local, ends.remote]
        }
        return args
    }

    // MARK: - Bestandslauf

    public enum InventorySide: Sendable {
        /// Die Gegenstelle. Braucht die Remote-Shell und kostet eine Anmeldung.
        case remote
        /// Dieser Rechner. Laeuft ohne ssh.
        case local
    }

    public struct InventoryOptions: Sendable {
        public var side: InventorySide
        /// Leerer Ordner als Ziel. Wird nicht angefasst, `--dry-run` sorgt dafuer.
        public var emptyDirectory: String
        /// Nur fuer `.remote` noetig.
        public var remoteShell: String?
        /// Ohne Ausschlussdatei kommt heraus, was die Ausschluesse sonst verdecken.
        public var excludeFile: String?
        /// Pruefsummen mitnehmen. Nur mit rsync 3.x, openrsync kennt `%C` nicht.
        public var wantsChecksums: Bool
        /// Namen unmaskiert ausgeben (`-8`).
        ///
        /// Ohne das schreibt openrsync "Ümläut" als "\#303\#234ml…", und ein
        /// Werkzeug, das die Liste weiterverarbeitet, findet die Datei nicht.
        /// Nur der Backup-Lauf setzt es: Die gespeicherten Bestandslisten
        /// enthalten die maskierte Schreibweise, ein Wechsel im Pruefpfad liesse
        /// jeden Umlautpfad als geloescht und neu erscheinen.
        public var wantsRawNames: Bool
        /// `nil` heisst: auf dem alten Weg aus dem Profil ableiten.
        public var endpoints: SyncEndpoints?

        public init(
            side: InventorySide,
            emptyDirectory: String,
            remoteShell: String? = nil,
            excludeFile: String? = nil,
            wantsChecksums: Bool = false,
            wantsRawNames: Bool = false,
            endpoints: SyncEndpoints? = nil
        ) {
            self.side = side
            self.emptyDirectory = emptyDirectory
            self.remoteShell = remoteShell
            self.excludeFile = excludeFile
            self.wantsChecksums = wantsChecksums
            self.wantsRawNames = wantsRawNames
            self.endpoints = endpoints
        }
    }

    /// Vollstaendige Auflistung einer Seite.
    ///
    /// Der Kniff ist das leere Zielverzeichnis: dann fehlt jeder Eintrag beim
    /// Empfaenger, und rsync itemisiert ihn. Heraus kommt dasselbe Format, das
    /// `ItemizeParser` ohnehin liest, samt leerer Ordner und Symlinks.
    ///
    /// `--dry-run` steht fest verdrahtet drin, und `--delete` gibt es hier gar
    /// nicht: Ein Bestandslauf darf unter keinen Umstaenden etwas anfassen.
    public static func inventoryArguments(
        profile: Profile, options: InventoryOptions
    ) -> [String] {
        // Kein `-z`: es wird nichts uebertragen, komprimiert wird nur die Luft.
        var args = ["-rlpt", "--dry-run", "--itemize-changes"]
        if options.wantsRawNames { args.append("-8") }
        args.append(
            "--out-format=\(options.wantsChecksums ? ItemizeParser.inventoryChecksumFormat : ItemizeParser.inventoryFormat)"
        )
        if options.wantsChecksums { args.append("--checksum") }
        if let excludeFile = options.excludeFile { args.append("--exclude-from=\(excludeFile)") }

        let ends = options.endpoints ?? SyncEndpoints.resolve(profile: profile)
        switch options.side {
        case .remote:
            if let remoteShell = options.remoteShell { args += ["-e", remoteShell] }
            args.append(ends.remote)
        case .local:
            args.append(ends.local)
        }

        let destination = options.emptyDirectory.hasSuffix("/")
            ? options.emptyDirectory : options.emptyDirectory + "/"
        args.append(destination)
        return args
    }

    /// Schreibt Schutzregeln fuer `--filter=merge`. Ohne Pfade keine Datei.
    ///
    /// Die Pfade stammen aus der Auswertung, nicht vom Nutzer, koennen aber
    /// Sonderzeichen enthalten. rsync liest `*`, `?` und `[` als Muster,
    /// deshalb der Backslash davor.
    public static func writeProtectFile(_ paths: [String], in directory: URL) throws -> String? {
        let rules = paths
            .map { path -> String in
                let escaped = path.map { character -> String in
                    "*?[".contains(character) ? "\\\(character)" : String(character)
                }.joined()
                return "P /" + escaped
            }
        guard !rules.isEmpty else { return nil }
        let url = directory.appendingPathComponent("protect")
        try (rules.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// Schreibt die Ausschlussliste in eine Datei fuer `--exclude-from`.
    public static func writeExcludeFile(_ patterns: [String], in directory: URL) throws -> String? {
        let cleaned = patterns
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        let url = directory.appendingPathComponent("excludes")
        try (cleaned.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
}
