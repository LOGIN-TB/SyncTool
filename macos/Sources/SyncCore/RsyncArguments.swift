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
        /// Datei mit den Einschlussregeln des Git-Laufs. Nur `gitArguments`
        /// liest sie, der Hauptlauf schliesst dieselben Zweige aus.
        public var gitFilterFile: String?
        /// Notbremse des Git-Laufs. Aus der Pruefung gemessen, nicht aus dem
        /// Profil: nach einem `git gc` faellt drueben ein Vielfaches von
        /// `maxDelete` weg, und der Lauf duerfte trotzdem nicht stehenbleiben.
        public var gitMaxDelete: Int

        public init(
            dryRun: Bool,
            includeDeletes: Bool,
            remoteShell: String,
            excludeFile: String? = nil,
            protectFile: String? = nil,
            endpoints: SyncEndpoints? = nil,
            flavour: RsyncFlavour = .sshRsync,
            gitFilterFile: String? = nil,
            gitMaxDelete: Int = 0
        ) {
            self.dryRun = dryRun
            self.includeDeletes = includeDeletes
            self.remoteShell = remoteShell
            self.excludeFile = excludeFile
            self.protectFile = protectFile
            self.endpoints = endpoints
            self.flavour = flavour
            self.gitFilterFile = gitFilterFile
            self.gitMaxDelete = gitMaxDelete
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

    // MARK: - Git-Lauf

    /// Die Zeile fuer den Lauf, der `.git` als Einheit uebertraegt.
    ///
    /// Zwei Abweichungen vom Hauptlauf, beide mit Absicht:
    ///
    /// Ohne die Ausschlussliste des Nutzers. Innerhalb eines Zweigs, der
    /// gespiegelt wird, hiesse `*.log` sonst, dass ein `.git/gc.log` der
    /// Empfaengerseite ueberlebt: Ausschluss ist bei rsync zugleich Schutz vor
    /// dem Loeschen. Heraus kaeme wieder ein halbes `.git`.
    ///
    /// `--delete` unabhaengig von `deleteAllowed` und vom Haken im
    /// Statusfenster. Ohne Loeschen innerhalb von `.git/` ueberleben lose Refs,
    /// ein alter `packed-refs` und ein alter `index`, und genau daraus entsteht
    /// die Meldung "N commits behind". Geraeumt wird nur, was die Filterdatei
    /// aufnimmt, alles andere ist ausgeschlossen und damit geschuetzt.
    public static func gitArguments(
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
        if let filter = options.gitFilterFile { args.append("--filter=merge \(filter)") }

        if options.flavour.usesRemoteShell { args += ["-e", options.remoteShell] }

        if options.dryRun {
            args.append("--dry-run")
        } else {
            args += ["--partial", "--partial-dir=.synctool-partial", "--stats"]
        }

        args.append("--delete")
        args.append("--max-delete=\(options.gitMaxDelete)")

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
        let rules = paths.map { "P /" + escape($0) }
        guard !rules.isEmpty else { return nil }
        let url = directory.appendingPathComponent("protect")
        try (rules.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// Maskiert die Musterzeichen in einem gemessenen Pfad.
    ///
    /// Die Pfade stammen aus der Auswertung, nicht vom Nutzer, koennen aber
    /// Sonderzeichen enthalten. rsync liest `*`, `?` und `[` als Muster.
    static func escape(_ path: String) -> String {
        path.map { "*?[".contains($0) ? "\\\($0)" : String($0) }.joined()
    }

    /// Schreibt die Filterdatei fuer den Git-Lauf.
    ///
    /// Aufgenommen wird nur, was zu den freigegebenen `.git`-Zweigen gehoert,
    /// alles andere faellt mit der letzten Zeile heraus. Ausgeschlossene
    /// Eintraege schuetzt rsync von sich aus vor `--delete`, solange
    /// `--delete-excluded` fehlt; das gilt fuer rsync 3.x und openrsync
    /// gleichermassen.
    ///
    /// Jedes Elternsegment braucht eine eigene Zeile, sonst steigt rsync gar
    /// nicht erst in den Ordner hinab. Dieselben Zeilen legen den Repo-Ordner
    /// an, falls es ihn auf der Empfaengerseite noch nicht gibt.
    public static func writeGitFilterFile(
        branches: [String], in directory: URL
    ) throws -> String? {
        var rules = ["- .synctool-partial/"]
        var seen: Set<String> = []
        for branch in branches.sorted() {
            for prefix in ancestors(of: branch) where seen.insert(prefix).inserted {
                rules.append("+ /" + escape(prefix))
            }
            rules.append("+ /" + escape(branch) + "**")
        }
        // Ohne diese Zeile naehme der Lauf den ganzen Baum mit.
        rules.append("- *")
        guard rules.count > 2 else { return nil }
        let url = directory.appendingPathComponent("gitfilter")
        try (rules.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// `a/b/.git/` ergibt `a/`, `a/b/`, `a/b/.git/`.
    private static func ancestors(of branch: String) -> [String] {
        let segments = branch.split(separator: "/", omittingEmptySubsequences: true)
        var walked = ""
        return segments.map { segment in
            walked += segment + "/"
            return walked
        }
    }

    /// Schreibt die Ausschlussliste in eine Datei fuer `--exclude-from`.
    ///
    /// Die `.git`-Zweige kommen hinter die Muster des Nutzers. Sie stehen als
    /// verankerte Pfade da, nicht als Regelzeilen mit Vorzeichen: in einer
    /// Datei fuer `--exclude-from` ist ohnehin jede Zeile ein Ausschluss, und
    /// die Reihenfolge spielt dann keine Rolle.
    public static func writeExcludeFile(
        _ patterns: [String], branches: [String] = [], in directory: URL
    ) throws -> String? {
        let cleaned = patterns
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            + branches.sorted().map { "/" + escape($0) }
        guard !cleaned.isEmpty else { return nil }
        let url = directory.appendingPathComponent("excludes")
        try (cleaned.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
}
