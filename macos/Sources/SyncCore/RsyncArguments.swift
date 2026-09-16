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
        /// Notbremse des Hauptlaufs. `nil` heisst: es gab keine Messung, dann
        /// gilt `profile.maxDelete` wie eh und je.
        public var maxDelete: Int?
        /// Wohin die Empfaengerseite legt, was sie ersetzt oder loescht.
        /// Relativ zum Ziel, siehe `VersionFolder`. `nil` heisst: keine
        /// Sicherungen, dann ist jedes Ueberschreiben endgueltig.
        public var backupDir: String?
        /// Vertraegt die laufende rsync-Fassung `-b` und `--delete` in
        /// derselben Zeile? Bei openrsync nicht, siehe `backupFlags`.
        public var supportsBackupWhileDeleting: Bool
        /// Datei mit den Pfaden, die dieser Lauf uebertragen soll, einer je
        /// Zeile und nullterminiert. `nil` heisst: keine Messung, dann geht der
        /// ganze Baum wie frueher. Siehe `writeFilesFromFile`.
        public var filesFromFile: String?

        public init(
            dryRun: Bool,
            includeDeletes: Bool,
            remoteShell: String,
            excludeFile: String? = nil,
            protectFile: String? = nil,
            endpoints: SyncEndpoints? = nil,
            flavour: RsyncFlavour = .sshRsync,
            gitFilterFile: String? = nil,
            gitMaxDelete: Int = 0,
            maxDelete: Int? = nil,
            backupDir: String? = nil,
            supportsBackupWhileDeleting: Bool = true,
            filesFromFile: String? = nil
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
            self.maxDelete = maxDelete
            self.backupDir = backupDir
            self.supportsBackupWhileDeleting = supportsBackupWhileDeleting
            self.filesFromFile = filesFromFile
        }

        /// Die zwei Flags, die aus jedem Ueberschreiben eine verschobene Datei
        /// machen. Nur im echten Lauf: ein Trockenlauf schreibt nichts, und
        /// die Flags stuenden dann nur im Protokoll herum.
        ///
        /// Und nicht zusammen mit `--delete`, solange openrsync laeuft. Diese
        /// Fassung hoert in der Kombination still auf zu loeschen: kein
        /// Abbruch, keine Meldung, Status 0, und die Empfaengerseite behaelt
        /// Dateien, die der Nutzer im Ruecksprachefenster zum Loeschen
        /// freigegeben hat. Gemessen mit `env -i PATH=/usr/bin:/bin`, also
        /// openrsync gegen sich selbst; mit einem rsync 3.x im Pfad faellt es
        /// nicht auf, weil openrsync dann jenes als Gegenstelle startet.
        /// Belegt in den Integrationstests gegen beide Fassungen.
        ///
        /// Lieber loeschen ohne Sicherung als eine Sicherung, die das Loeschen
        /// verschluckt: Ein Lauf, der sich anders verhaelt als angekuendigt,
        /// ist der Anfang jedes Auseinanderlaufens.
        func backupFlags(deleting: Bool) -> [String] {
            guard !dryRun, let backupDir else { return [] }
            if deleting && !supportsBackupWhileDeleting { return [] }
            return ["-b", "--backup-dir=\(backupDir)"]
        }
    }

    /// Der Lauf, der Inhalte uebertraegt.
    ///
    /// Mit `options.filesFromFile` geht genau die gemessene Menge hinueber und
    /// sonst nichts. Das ist der Unterschied, um den es geht: Frueher war das
    /// hier ein voller einseitiger rsync ueber den ganzen Baum, und der fasste
    /// auch Dateien an, die die Pruefung der anderen Richtung zugeordnet
    /// hatte. Wer "Hochladen" drueckte, ueberschrieb damit die neuere Fassung
    /// der Gegenstelle mit der aelteren von hier, und jeder gemeldete Konflikt
    /// wurde einseitig plattgemacht, obwohl direkt daneben stand, dass genau
    /// das passiert.
    ///
    /// Konflikte stehen in keiner der beiden Listen und bleiben dadurch
    /// unberuehrt, ohne dass es dafuer eine eigene Regel braucht.
    ///
    /// Ohne Liste verhaelt sich die Funktion wie frueher, damit ein Aufruf
    /// ohne vorherige Pruefung gueltig bleibt.
    ///
    /// `--update` waere die billige Antwort gewesen und deckt den Fall nicht:
    /// Es uebertraegt "gleiche Zeit, anderer Inhalt", also genau einen der
    /// Konfliktfaelle. Bei beidseitiger Arbeit schickt es die juengere Fassung
    /// und wirft die andere weg. Und geht die Uhr der Gegenstelle vor,
    /// ueberspringt es beim Hochladen alles und meldet Erfolg. Ein stiller
    /// Nichtlauf ist schlimmer als ein lauter Fehler.
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

        // `--from0` dazu: Dann ist das Trennzeichen das Nullbyte, und die Namen
        // stehen roh in der Datei. Kein Muster, kein Backslash, keine Frage,
        // wie ein Zeilenumbruch im Dateinamen zu lesen waere.
        if let filesFrom = options.filesFromFile {
            args += ["--files-from=\(filesFrom)", "--from0"]
        }

        // Ohne Gegenstelle kein `-e`. Ein lokaler Lauf braucht keine Shell,
        // und rsync wuerde die Angabe als Fehler auslegen.
        if options.flavour.usesRemoteShell { args += ["-e", options.remoteShell] }

        if options.dryRun {
            args.append("--dry-run")
        } else {
            args += ["--partial", "--partial-dir=.synctool-partial", "--stats"]
        }

        // Loeschen laeuft nie beilaeufig mit: der Aufrufer muss es anfordern,
        // und das Profil muss es erlauben. Mit einer Pfadliste gar nicht mehr:
        // Dieser Lauf sieht nur die genannten Pfade, ein `--delete` daneben
        // haette keinen Bezug zum Rest des Baums. Geraeumt wird in
        // `deleteArguments`.
        let deleting = options.includeDeletes && profile.deleteAllowed
            && options.filesFromFile == nil
        args += options.backupFlags(deleting: deleting)

        if deleting {
            args.append("--delete")
            // Bricht ab, statt mehr zu loeschen. Die Vorschau kommt aus den
            // Bestaenden, dieser Lauf hier ist immer der echte.
            args.append("--max-delete=\(options.maxDelete ?? profile.maxDelete)")
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

    // MARK: - Löschlauf

    /// Die Zeile fuer den Lauf, der nur aufraeumt.
    ///
    /// Getrennt vom Inhalt, weil die beiden Risiken verschieden sind: Der
    /// Inhaltslauf schreibt, was die Pruefung benannt hat, dieser hier entfernt
    /// Eintraege, die es auf der Senderseite nicht mehr gibt. In einem Lauf
    /// zusammengefasst waeren sie nicht einzeln zu bewerten.
    ///
    /// `--existing --ignore-existing`: Dieser Lauf legt nichts an und ersetzt
    /// nichts. Er raeumt nur. Damit kann er den vollen Baum sehen, ohne dass
    /// eine Entscheidung des Inhaltslaufs noch einmal ueberschrieben wird.
    ///
    /// `--delete-after` statt des voreingestellten `--delete-during`: Bricht
    /// der Lauf mittendrin ab, hat die Empfaengerseite noch alle Daten. Vorher
    /// zu loeschen hiesse, im Abbruchfall Loecher zu hinterlassen.
    ///
    /// Die Reihenfolge im Motor ist Inhalt vor Loeschen. Eine umbenannte Datei
    /// geht so erst unter dem neuen Namen hinueber und faellt danach unter dem
    /// alten weg; zu keinem Zeitpunkt fehlt sie auf der Gegenseite.
    public static func deleteArguments(
        profile: Profile,
        direction: SyncDirection,
        options: Options
    ) -> [String] {
        var args = options.flavour.baseFlags
        args += [
            "--itemize-changes",
            "--out-format=\(ItemizeParser.outFormat)",
            "--modify-window=1",
            "--existing",
            "--ignore-existing",
        ]

        // Schutzregeln vor die Ausschluesse: bei rsync gewinnt die erste
        // passende Regel.
        if let protectFile = options.protectFile { args.append("--filter=merge \(protectFile)") }
        if let excludeFile = options.excludeFile { args.append("--exclude-from=\(excludeFile)") }

        if options.flavour.usesRemoteShell { args += ["-e", options.remoteShell] }

        if options.dryRun {
            args.append("--dry-run")
        } else {
            args.append("--stats")
        }
        args += options.backupFlags(deleting: true)

        args += ["--delete", "--delete-after"]
        args.append("--max-delete=\(options.maxDelete ?? profile.maxDelete)")

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
    /// Ohne `-b --backup-dir`. Geraeumt wird hier nur innerhalb eines `.git/`,
    /// dessen Inhalt in diesem Moment vollstaendig auf der Senderseite liegt:
    /// Was hier wegfaellt, ist wiederherstellbar, und eine Sicherung davon
    /// waere keine Vorsicht, sondern Ballast. Nach jedem `git gc` wanderten
    /// sonst die alten Packdateien mit, hunderte Megabyte je Lauf, und die
    /// Gegenstelle liefe voll. Gesichert wird da, wo Arbeit des Nutzers
    /// steht, und das ist der Hauptlauf.
    ///
    /// Dazu kommt ein gemessener Grund: Mit `--backup-dir` setzt openrsync in
    /// dieser Zeile das Loeschen aus, ohne es zu melden. Der Integrationstest
    /// "Ein Repo geht als Ganzes hinueber" faellt dann um.
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
        /// Ohne das schreibt openrsync einen Gedankenstrich als
        /// `\#342\#200\#223`, rsync 3.x nicht. Zwei Folgen, beide schlecht:
        /// Jede Regel, die aus so einem Pfad gebaut wird, geht am echten
        /// Dateinamen vorbei, und ein Wechsel des rsync-Binaries aendert die
        /// Schreibweise im gespeicherten Bestand, womit jeder betroffene Pfad
        /// einmalig als geloescht und neu gilt.
        ///
        /// Frueher stand hier, openrsync koenne `-8` nicht. Nachgemessen: es
        /// kann, und die Ausgabe ist dann unmaskiert. Deshalb jetzt ueberall
        /// an. Die gespeicherten Bestaende aus der Zeit davor tragen die
        /// maskierte Schreibweise; dafuer springt `SyncInventory.currentSchema`
        /// auf 3 und laesst sie einmalig geradeziehen.
        public var wantsRawNames: Bool
        /// `nil` heisst: auf dem alten Weg aus dem Profil ableiten.
        public var endpoints: SyncEndpoints?

        public init(
            side: InventorySide,
            emptyDirectory: String,
            remoteShell: String? = nil,
            excludeFile: String? = nil,
            wantsChecksums: Bool = false,
            wantsRawNames: Bool = true,
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

    /// Schreibt die Pfadliste fuer `--files-from --from0`.
    ///
    /// Nullterminiert und ohne `escape`: In dieser Datei steht kein Muster,
    /// sondern ein Name. rsync liest ihn woertlich, deshalb waere jedes
    /// Maskierzeichen hier ein Fehler und kein Schutz.
    ///
    /// Jedem Eintrag steht `./` voran. Ohne das faellt ein Pfad, der mit `#`
    /// oder `;` beginnt, still aus: rsync liest solche Zeilen als Kommentar,
    /// und zwar auch mit `--from0`. Gemessen mit beiden Fassungen, beide
    /// uebertrugen die Datei einfach nicht und meldeten nichts. Mit `./` davor
    /// kommt jeder Name durch, auch `-minus.txt`, `;semi.txt` und Namen mit
    /// Leerzeichen.
    public static func writeFilesFromFile(
        _ paths: [String], in directory: URL
    ) throws -> String? {
        guard !paths.isEmpty else { return nil }
        let url = directory.appendingPathComponent("filesfrom")
        let joined = paths.map { "./" + $0 }.joined(separator: "\0") + "\0"
        try Data(joined.utf8).write(to: url, options: .atomic)
        return url.path
    }

    /// Maskiert die Musterzeichen in einem gemessenen Pfad.
    ///
    /// Die Pfade stammen aus der Auswertung, nicht vom Nutzer, koennen aber
    /// Sonderzeichen enthalten. rsync liest `*`, `?` und `[` als Muster.
    ///
    /// Der Backslash steht bewusst als erstes in der Liste: In rsyncs
    /// Filtersprache ist er selbst das Maskierzeichen und muss deshalb
    /// zuerst verdoppelt werden, sonst frisst er das Zeichen dahinter.
    /// Das trifft jeden Pfad, den openrsync ohne `-8` maskiert ausgibt:
    /// Eine Schutzregel fuer so einen Namen ginge ins Leere, und
    /// `--delete` raeumte genau die Datei weg, die sie schuetzen sollte.
    static func escape(_ path: String) -> String {
        path.map { "\\*?[".contains($0) ? "\\\($0)" : String($0) }.joined()
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

    /// Schreibt die Filterdatei fuer den Ref-Lauf.
    ///
    /// Nur `HEAD`, `packed-refs` und alles unter `refs/`. Das sind ein paar
    /// Kilobyte je Repo, und daran laesst sich ablesen, ob beide Seiten auf
    /// demselben Stand stehen, ohne die Packdateien anzufassen.
    public static func writeRefFilterFile(
        branches: [String], in directory: URL
    ) throws -> String? {
        var rules: [String] = []
        var seen: Set<String> = []
        for branch in branches.sorted() {
            for prefix in ancestors(of: branch) where seen.insert(prefix).inserted {
                rules.append("+ /" + escape(prefix))
            }
            let root = "/" + escape(branch)
            rules.append("+ " + root + "HEAD")
            rules.append("+ " + root + "packed-refs")
            rules.append("+ " + root + "refs/")
            rules.append("+ " + root + "refs/**")
        }
        guard !rules.isEmpty else { return nil }
        rules.append("- *")
        let url = directory.appendingPathComponent("reffilter")
        try (rules.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// Holt die Refs der Gegenseite in einen Arbeitsordner.
    ///
    /// Kein `--delete`, kein `--checksum`, keine Ausschlussliste: der Ordner ist
    /// jedes Mal neu und wird nach dem Lauf weggeraeumt.
    public static func refArguments(
        profile: Profile,
        filterFile: String,
        destination: String,
        remoteShell: String,
        flavour: RsyncFlavour,
        endpoints: SyncEndpoints? = nil
    ) -> [String] {
        var args = ["-rlpt", "--filter=merge \(filterFile)"]
        if flavour.usesRemoteShell { args += ["-e", remoteShell] }
        let ends = endpoints ?? SyncEndpoints.resolve(profile: profile)
        args.append(ends.remote)
        args.append(destination.hasSuffix("/") ? destination : destination + "/")
        return args
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
