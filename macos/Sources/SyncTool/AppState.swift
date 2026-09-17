import AppKit
import Foundation
import SwiftUI
import SyncCore

/// Was im Detailbereich der Einstellungen steht.
///
/// "Allgemein" ist kein Profil, deshalb ein eigener Fall statt eines
/// Sonderwerts in der Kennung.
enum SettingsSelection: Hashable {
    case profile(UUID)
    case general

    var profileID: UUID? {
        if case .profile(let id) = self { return id }
        return nil
    }
}

/// Welcher Reiter im Profileditor oben liegt.
///
/// Als Zustand der App und nicht nur im `TabView`, damit die Auswahl von aussen
/// setzbar ist: die Bildschirmfoto-Werkstatt braucht jeden Reiter einzeln, und
/// von Hand durchklicken waere keine Werkstatt.
enum EditorTab: String, CaseIterable {
    case verbindung, abgleich, backup
}

enum Phase: Equatable {
    case idle
    case checking
    case transferring(SyncDirection)
    case backingUp
    /// Der Abgleich mit der Gegenstelle, mit Zaehler: Jedes Repo kostet ein
    /// `fetch` ueber das Netz, und ohne Zaehler sieht es aus, als passiere
    /// nichts.
    case reconciling(done: Int, total: Int, name: String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .transferring, .backingUp, .reconciling: return true
        case .idle, .failed: return false
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var selectedProfileID: UUID?
    @Published var password: String = ""
    @Published var status: SyncStatus?
    @Published var phase: Phase = .idle
    @Published var progress: TransferProgress?
    @Published var log: [String] = []
    @Published var rsyncInfo: RsyncInfo?
    /// `nil` heisst: kein git gefunden. Dann laeuft der Abgleich mit der
    /// Gegenstelle nicht, der Abgleich mit dem Sync-Ziel sehr wohl.
    @Published var gitInfo: GitInfo?
    /// Ergebnis des letzten Abgleichs mit der Gegenstelle, je Repo-Stamm.
    @Published var gitResults: [String: GitRepoResult] = [:]

    /// Der Pruefstand, nachdem die Gegenstelle einen Gleichstand aufgebrochen
    /// hat. Ueberall zu benutzen, wo es um Knoepfe und Uebertragung geht:
    /// `status` allein weiss nichts von der Gegenstelle.
    var resolvedStatus: SyncStatus? {
        status?.resolvingGitUnits(with: gitResults)
    }
    @Published var hostKeyCandidates: [HostKeyCandidate] = []
    @Published var notice: String?
    @Published var lastBackup: BackupResult?
    /// Was im Einstellungsfenster bearbeitet wird.
    ///
    /// Bewusst getrennt von `selectedProfileID`: Ein Einstellungsfenster darf
    /// nicht aendern, was der Knopf "Hochladen" tut. Blaettern darin wuerde
    /// sonst das Sync-Ziel umstellen und nebenbei das Pruefergebnis verwerfen.
    @Published var editingSelection: SettingsSelection?
    @Published var editorTab: EditorTab = .verbindung
    /// Meldungen des Einstellungsfensters. Getrennt von `notice`, sonst
    /// erscheint "Passwort gesichert" im Menueleisten-Popover und `check()`
    /// raeumt umgekehrt die Meldung der Einstellungen weg.
    @Published var settingsNotice: String?
    /// Gesetzt, wenn profiles.json da, aber unlesbar ist. Solange das steht,
    /// wird nichts gespeichert: sonst ueberschreibt ein leeres Ersatzprofil die
    /// echten Zugangsdaten.
    @Published var profilesUnreadable: String?

    private let profileStore = ProfileStore()
    private let keychain = KeychainStore()
    /// Der laufende Schluesselbund-Zugriff. Siehe `loadPassword`.
    private var passwordLoad: Task<Void, Never>?
    private let stateStore = SyncStateStore()
    /// Das Protokoll auf Platte. Siehe `RunLog`.
    private let runLog = RunLog()
    private let inventoryStore = InventoryStore()
    /// Ein Prozess zur Zeit, ein Abbruchknopf fuer alles. Pruefen, Uebertragen
    /// und Backup teilen sich denselben Runner.
    private let processRunner = ProcessRunner()
    private lazy var runner = RsyncRunner(process: processRunner)
    private lazy var engine = SyncEngine(
        runner: runner, stateStore: stateStore, inventoryStore: inventoryStore
    )
    private lazy var backupEngine = BackupEngine(runner: processRunner)
    private let keySetup = SSHKeySetup()

    /// Grenze fuer das Protokoll im Popover; ein voller Sync erzeugt sonst
    /// zehntausende Zeilen im Speicher.
    private let logLimit = 2000

    /// Eine Aenderung, ein geplanter Schreibvorgang.
    ///
    /// Die Bindungen im Einstellungsfenster feuern bei jedem Tastendruck; ohne
    /// Sammelfrist schriebe ein getippter Servername dreissig Dateien statt einer.
    private var pendingSave: Task<Void, Never>?
    /// Zuletzt geschriebener Stand. Spart den Schreibvorgang, wenn ein Fenster
    /// geschlossen wird, in dem nichts geaendert wurde.
    private var lastSaved: [Profile] = []

    init() {
        switch profileStore.loadResult() {
        case .profiles(let loaded):
            // Eine bewusst leer gespeicherte Liste bleibt leer. Nur eine
            // fehlende Datei ist ein erster Start und bekommt ein Startprofil.
            profiles = loaded
        case .empty:
            profiles = [Profile()]
        case .unreadable(let reason):
            // Nicht mit einem leeren Profil weitermachen: Die Datei ist da, nur
            // nicht lesbar, und das erste Speichern wuerde sie ueberschreiben.
            profiles = [Profile()]
            profilesUnreadable = reason
        }
        selectedProfileID = profiles.first?.id
        lastSaved = profiles
        loadPassword()
        // Ohne das geht ein neu angelegtes Profil verloren, wenn die App ueber
        // "Beenden" im Statusfenster endet, waehrend die Einstellungen offen
        // sind: `onDisappear` feuert dann nicht.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSave() }
        }
        // Eine Zeile beim Start, damit die Protokolldatei da ist und man ihr
        // ansieht, welche Fassung gelaufen ist. Wer hinterher einen Abbruch
        // untersucht, will als Erstes wissen, womit.
        runLog.write("SyncTool \(AppVersion.display) gestartet")
        Task { await refreshRsync(preferred: selectedProfile?.rsyncPath ?? "") }
        Task { await refreshGit() }
    }

    // MARK: - Profile

    var selectedProfile: Profile? {
        get { profiles.first { $0.id == selectedProfileID } }
        set {
            guard let newValue, let index = profiles.firstIndex(where: { $0.id == newValue.id })
            else { return }
            profiles[index] = newValue
        }
    }

    var lastSync: Date? {
        guard let profile = selectedProfile else { return nil }
        return stateStore.load().lastSync(for: profile)
    }

    /// Das gerade bearbeitete Profil. Nicht zu verwechseln mit `selectedProfile`,
    /// das am Sync-Ziel haengt.
    var editingProfile: Profile? {
        get {
            guard let id = editingSelection?.profileID else { return nil }
            return profiles.first { $0.id == id }
        }
        set {
            guard let newValue, let index = profiles.firstIndex(where: { $0.id == newValue.id })
            else { return }
            profiles[index] = newValue
            scheduleSave()
        }
    }

    /// Setzt die Bearbeitungsauswahl beim Oeffnen des Fensters.
    ///
    /// Faellt auf das aktive Profil zurueck, wenn noch nichts oder nichts
    /// Gueltiges gewaehlt ist: Wer das Zahnrad drueckt, will meistens das
    /// ansehen, was gerade laeuft.
    func beginEditing() {
        if let id = editingSelection?.profileID, profiles.contains(where: { $0.id == id }) {
            return
        }
        if editingSelection == .general { return }
        editingSelection = selectedProfileID.map(SettingsSelection.profile)
            ?? profiles.first.map { .profile($0.id) }
    }

    /// Waehlt ein Profil ueber seinen Namen zum Bearbeiten aus.
    ///
    /// Nur fuer die Startargumente. Der Name statt der Kennung, weil eine UUID
    /// auf einer Kommandozeile niemand tippt, und mit `hasPrefix`, damit ein
    /// Teilstueck genuegt.
    func selectProfileForEditing(named name: String) {
        let lowered = name.lowercased()
        guard
            let match = profiles.first(where: { $0.name.lowercased().hasPrefix(lowered) })
                ?? profiles.first(where: { $0.name.lowercased().contains(lowered) })
        else { return }
        editingSelection = .profile(match.id)
    }

    /// Macht das bearbeitete Profil zum aktiven Ziel. Der einzige Weg von der
    /// Bearbeitungs- zur Sync-Auswahl.
    func activateEditedProfile() {
        guard let id = editingSelection?.profileID, id != selectedProfileID else { return }
        selectProfile(id)
    }

    @discardableResult
    func addProfile() -> UUID {
        let profile = Profile(name: ProfileList.uniqueName("Neues Ziel", among: profiles.map(\.name)))
        profiles.append(profile)
        editingSelection = .profile(profile.id)
        if selectedProfileID == nil { selectedProfileID = profile.id }
        flushSave()
        return profile.id
    }

    @discardableResult
    func duplicateProfile(id: UUID) -> UUID? {
        let (updated, newID) = ProfileList.inserted(duplicateOf: id, into: profiles)
        guard let newID else { return nil }
        profiles = updated
        editingSelection = .profile(newID)
        flushSave()
        return newID
    }

    /// Loescht Profil, Bestandsliste und den Eintrag in state.json.
    ///
    /// Der Schluesselbundeintrag bleibt: Er haengt an Server, Port und Benutzer,
    /// ein zweites Profil kann denselben benutzen, und das stille Entfernen
    /// eines Zugangs ist keine Nebenwirkung, die eine Profilloeschung haben darf.
    func removeProfile(id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        inventoryStore.remove(for: profile)
        stateStore.forget(id)

        let (updated, next) = ProfileList.removing(id, from: profiles)
        profiles = updated
        editingSelection = next.map(SettingsSelection.profile)

        if selectedProfileID == id {
            selectedProfileID = next
            status = nil
            progress = nil
            lastBackup = nil
            loadPassword()
        }
        flushSave()
    }

    /// Sammelt Aenderungen und schreibt einmal.
    func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.saveProfiles()
        }
    }

    /// Sofort schreiben und die Sammelfrist abraeumen. Ueberall dort noetig, wo
    /// die App verschwinden kann oder ein Prozess mit dem Profil arbeitet.
    func flushSave() {
        pendingSave?.cancel()
        pendingSave = nil
        saveProfiles()
    }

    func saveProfiles() {
        guard profilesUnreadable == nil else {
            settingsNotice =
                "Profile werden nicht gespeichert, solange profiles.json nicht lesbar ist."
            return
        }
        guard profiles != lastSaved else { return }
        do {
            try profileStore.save(profiles)
            lastSaved = profiles
        } catch {
            settingsNotice = "Profile ließen sich nicht sichern: \(error.localizedDescription)"
        }
    }

    func selectProfile(_ id: UUID) {
        selectedProfileID = id
        status = nil
        progress = nil
        lastBackup = nil
        loadPassword()
        // Ohne das zeigt das Fenster die rsync-Fassung des vorherigen Profils.
        Task { await refreshRsync(preferred: selectedProfile?.rsyncPath ?? "") }
    }

    // MARK: - Passwort

    /// Holt das Passwort aus dem Schluesselbund, ohne die App anzuhalten.
    ///
    /// Frueher stand hier ein schlichter Aufruf, und der lief auf dem
    /// Hauptthread. Das ging gut, solange der Schluesselbund sofort antwortete.
    /// Nach jedem neuen Bau fragt macOS aber nach, ob dieses Programm an den
    /// Eintrag darf, und bis jemand den Dialog beantwortet, steht
    /// `SecItemCopyMatching` still. Weil der Aufruf aus `init` kam, stand damit
    /// die ganze App: kein Symbol in der Leiste, keine Protokollzeile, kein
    /// Fenster. Von aussen sieht das aus wie ein Absturz.
    ///
    /// Nachgemessen an einem haengenden Prozess: Der Hauptthread stand in
    /// `AppState.init` → `loadPassword` → `SecItemCopyMatching` und wartete auf
    /// `securityd`, waehrend der SecurityAgent im Hintergrund seinen Dialog
    /// offen hatte.
    ///
    /// Wer das Passwort braucht, wartet ueber `awaitPassword` darauf. Alle
    /// anderen laufen weiter.
    func loadPassword() {
        passwordLoad?.cancel()
        guard let profile = selectedProfile, !profile.host.isEmpty, !profile.user.isEmpty else {
            passwordLoad = nil
            password = ""
            return
        }
        let keychain = self.keychain
        let host = profile.host
        let port = profile.port
        let account = profile.user
        passwordLoad = Task { [weak self] in
            let wert = await Task.detached(priority: .userInitiated) {
                (try? keychain.load(host: host, port: port, account: account)) ?? ""
            }.value
            guard !Task.isCancelled else { return }
            self?.password = wert
        }
    }

    /// Wartet, bis der Schluesselbund geantwortet hat.
    ///
    /// Vor jedem Lauf, der das Passwort braucht. Ohne das liefe der erste Lauf
    /// nach dem Start mit einem leeren Passwort los.
    func awaitPassword() async {
        await passwordLoad?.value
    }

    /// Sichert oder loescht das Passwort eines bestimmten Profils.
    ///
    /// Nimmt Profil und Passwort als Parameter, weil das Einstellungsfenster ein
    /// anderes Profil bearbeitet als das gerade aktive. Am Ende zieht der
    /// Sync-Puffer nach, falls beide zufaellig dasselbe sind.
    func savePassword(_ value: String, for profile: Profile) {
        do {
            if value.isEmpty {
                try keychain.delete(host: profile.host, port: profile.port, account: profile.user)
                settingsNotice = "Passwort aus dem Schlüsselbund entfernt."
            } else {
                try keychain.save(
                    password: value, host: profile.host, port: profile.port, account: profile.user
                )
                settingsNotice = "Passwort im Schlüsselbund gesichert."
            }
        } catch {
            settingsNotice = error.localizedDescription
        }
        loadPassword()
    }

    /// Passwort eines beliebigen Profils lesen, fuer die Einstellungen.
    func password(for profile: Profile) -> String {
        (try? keychain.load(host: profile.host, port: profile.port, account: profile.user)) ?? ""
    }

    // MARK: - rsync

    /// Der Aufrufer entscheidet, wessen Pfad gilt.
    ///
    /// Vorher las die Funktion selbst `selectedProfile`, wurde aber beim
    /// Profilwechsel nie gerufen; die angezeigte Fassung war dann veraltet.
    /// Einmal beim Start. `/usr/bin/git` ist nur eine Weiche auf die Command
    /// Line Tools und oeffnet einen Systemdialog, wenn die fehlen; das gehoert
    /// nicht in jeden Lauf.
    func refreshGit() async {
        gitInfo = await GitLocator.locate()
    }

    func refreshRsync(preferred: String) async {
        rsyncInfo = await RsyncLocator.locate(preferred: preferred)
    }

    var rsyncWarning: String? {
        guard let info = rsyncInfo else {
            return "Kein rsync gefunden. Mit `brew install rsync` nachinstallieren."
        }
        guard info.isOpenRsync else { return nil }
        return "Es läuft openrsync aus dem System. Gegen rsync 3.x auf dem Server "
            + "ist das die anfälligere Kombination – `brew install rsync` behebt das."
    }

    // MARK: - Anbieterkatalog

    /// Die Vorlagen samt Sperrhinweis fuer alles, was noch ein Werkzeug braucht.
    var providerPresets: [ProviderPreset] {
        ProviderCatalog.presets(rcloneAvailable: false)
    }

    /// Setzt eine Vorlage auf ein Profil.
    func apply(_ preset: ProviderPreset, to profile: Profile) {
        guard var edited = profiles.first(where: { $0.id == profile.id }) else { return }
        preset.apply(to: &edited)
        // Ein Platzhaltername wird zum Namen der Vorlage, ein selbst gewaehlter
        // bleibt. Die Eindeutigkeit prueft ProfileList, weil sie die Liste
        // kennt und die Vorlage nicht.
        if ProviderPreset.nameIsPlaceholder(edited.name) {
            edited.name = ProfileList.uniqueName(
                preset.name, among: profiles.filter { $0.id != profile.id }.map(\.name)
            )
        }
        editingProfile = edited
        settingsNotice = nil
        flushSave()
    }

    // MARK: - Host-Key und Verbindung

    func fetchHostKeys() async {
        guard let profile = selectedProfile else { return }
        notice = nil
        do {
            hostKeyCandidates = try await HostKeyStore().fetchCandidates(
                host: profile.host, port: profile.port
            )
        } catch {
            notice = error.localizedDescription
        }
    }

    func trust(_ candidate: HostKeyCandidate) {
        do {
            try HostKeyStore().trust(candidate)
            hostKeyCandidates = []
            notice = "Host-Key gespeichert."
        } catch {
            notice = error.localizedDescription
        }
    }

    var hostKeyIsKnown: Bool {
        guard let profile = selectedProfile, !profile.host.isEmpty else { return false }
        // Ohne ssh gibt es keinen Host-Key. `false` waere hier eine Warnung
        // ueber etwas, das dieses Ziel gar nicht kennt.
        guard profile.transport.usesRemoteShell else { return true }
        return HostKeyStore().isKnown(host: profile.host, port: profile.port)
    }

    /// Ein Knopf, je Transportart ein anderer Ablauf.
    func testConnection(profile: Profile, password: String) async {
        settingsNotice = nil
        clearLog()

        // Der Stammordner hat mit einer Verbindung nichts zu tun. Frueher stand
        // hier ein Vergleich auf den Wortlaut der Meldung, der genau daran
        // scheiterte: ein frisches Profil konnte seine Verbindung nicht testen.
        let problems = profile.issues().filter { $0.field != .localRoot }
        guard problems.isEmpty else {
            settingsNotice = problems.map(\.message).joined(separator: " ")
            return
        }

        flushSave()
        switch profile.transport {
        case .sshRsync:
            await testSSH(profile: profile, password: password)
        case .localFolder:
            await testFolder(profile: profile)
        case .mountedVolume(let proto):
            // Das Einhaengen kommt erst noch. Bis dahin ein Satz statt eines
            // Fehlschlags mit unverstaendlicher Meldung.
            settingsNotice =
                "\(proto.label)-Ziele kann diese Version noch nicht einhängen. "
                + "Bis dahin hilft: die Freigabe im Finder verbinden und dann "
                + "„Externe Platte oder Ordner“ auf den Einhängepunkt richten."
            append(settingsNotice!)
        case .unknown(let raw):
            settingsNotice = "Unbekannte Art von Ziel: \(raw)."
        }
    }

    /// Ein lokales Ziel hat keine Verbindung. Geprueft wird, ob der Ordner da
    /// ist, ob sich darin schreiben laesst, und wie viel darin liegt.
    private func testFolder(profile: Profile) async {
        if let problem = profile.targetFolderIssue() {
            settingsNotice = problem.message
            append("Fehlgeschlagen: \(problem.message)")
            return
        }
        let url = URL(fileURLWithPath: profile.remotePath)
        guard FileManager.default.isWritableFile(atPath: profile.remotePath) else {
            settingsNotice = "In \(profile.remotePath) lässt sich nicht schreiben."
            append("Fehlgeschlagen: \(settingsNotice!)")
            return
        }
        let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.count ?? 0
        await stampTarget(
            profile,
            store: RemoteStore.make(
                profile: profile, session: nil,
                endpoints: SyncEndpoints.resolve(profile: profile)
            )
        )
        settingsNotice =
            "Zielordner ist da und beschreibbar, \(count) "
            + (count == 1 ? "Eintrag" : "Einträge") + " direkt darin."
        append(settingsNotice!)
    }

    /// Legt die Kennung im Ziel ab und merkt sie sich im Profil.
    ///
    /// Damit laesst sich der Ordner wiedererkennen, und ein Lauf gegen einen
    /// anderen faellt auf, bevor er etwas anfasst. Der gefaehrlichste Fall
    /// braucht dafuer keinen Fehler in der App: Die Platte ist nicht
    /// verbunden, und an ihrer Stelle steht ein leerer Ordner desselben Namens.
    ///
    /// Eine vorhandene Kennung bleibt stehen. Sie neu zu setzen hiesse, die
    /// Wiedererkennung fuer alle anderen Rechner zu zerstoeren, die auf
    /// denselben Ordner zeigen.
    private func remember(_ marker: String, for id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].targetMarkerID = marker
        profiles[index].probedAt = Date()
        scheduleSave()
    }

    private func stampTarget(_ profile: Profile, store: RemoteFiles?) async {
        guard let store else { return }
        if let vorhanden = await store.read(TargetMarker.fileName) {
            let gelesen = String(decoding: vorhanden, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !gelesen.isEmpty {
                remember(gelesen, for: profile.id)
                return
            }
        }
        let neu = profile.targetMarkerID.isEmpty ? TargetMarker.make() : profile.targetMarkerID
        do {
            try await store.write(
                Data(TargetMarker.contents(neu).utf8), to: TargetMarker.fileName
            )
            remember(neu, for: profile.id)
            append("Kennung im Ziel hinterlegt.")
        } catch {
            append("Die Kennung ließ sich nicht im Ziel ablegen: \(error.localizedDescription)")
        }
    }

    private func testSSH(profile: Profile, password: String) async {
        append("Verbinde mit \(profile.user)@\(profile.host):\(profile.port) …")
        do {
            let session = try SSHSession(profile: profile)
            defer { session.stop() }
            try session.start(password: password)
            let result = try await session.testConnection()
            if result.succeeded {
                await stampTarget(
                    profile,
                    store: RemoteStore.make(
                        profile: profile, session: session,
                        endpoints: SyncEndpoints.resolve(profile: profile)
                    )
                )
                settingsNotice = "Verbindung steht, Zielordner „\(profile.remotePath)“ ist vorhanden."
                append(settingsNotice!)
            } else {
                settingsNotice = result.errorSummary
                append("Fehlgeschlagen: \(result.errorSummary)")
            }
        } catch {
            settingsNotice = error.localizedDescription
            append("Fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    // MARK: - SSH-Key

    var keyExists: Bool { keySetup.keyExists }

    func setUpKey(profile: Profile, password: String) async {
        settingsNotice = nil
        flushSave()
        do {
            let comment = "SyncTool \(NSUserName())@\(Host.current().localizedName ?? "mac")"
            _ = try await keySetup.ensureKeyPair(comment: comment)

            var passwordProfile = profile
            passwordProfile.authMode = .password
            let session = try SSHSession(profile: passwordProfile)
            defer { session.stop() }
            try session.start(password: password)

            try await keySetup.install(
                using: session,
                // Die Vorlage weiss es. Der Hostname ist nur noch der Rueckfall
                // fuer Profile aus einer Fassung ohne Anbieterkatalog.
                isStorageBox: profile.providerID == "hetzner-storagebox"
                    || (profile.providerID.isEmpty
                        && profile.host.contains("your-storagebox.de"))
            )

            if var updated = profiles.first(where: { $0.id == profile.id }) {
                updated.authMode = .publicKey
                editingProfile = updated
            }
            flushSave()
            settingsNotice = "Schlüssel hinterlegt. Das Profil läuft ab jetzt ohne Passwort."
        } catch {
            settingsNotice = error.localizedDescription
        }
    }

    // MARK: - Prüfen und Übertragen

    func check() async {
        guard let profile = selectedProfile, let rsync = rsyncInfo else {
            notice = selectedProfile == nil
                ? "Kein Profil gewählt. In den Einstellungen eines anlegen." : rsyncWarning
            return
        }
        // Ein Prozess arbeitet gleich mit dem Profil; ungespeicherte
        // Aenderungen daran waeren eine Falle.
        flushSave()
        phase = .checking
        notice = nil
        progress = nil
        // Sonst bliebe das Backup-Ergebnis stehen und verdeckte die Prüfung.
        lastBackup = nil
        clearLog()
        runner.resetCancellation()
        // Der Schluesselbund kann beim ersten Mal nachfragen. Siehe `loadPassword`.
        await awaitPassword()

        do {
            let result = try await engine.check(
                profile: profile,
                password: password,
                rsyncPath: rsync.path,
                // openrsync kennt das Prüfsummenfeld nicht.
                supportsChecksumField: !rsync.isOpenRsync,
                onLog: { [weak self] line in
                    Task { @MainActor in self?.append(line) }
                }
            )
            status = result
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
            append("Abgebrochen: \(error.localizedDescription)")
        }
    }

    func transfer(_ direction: SyncDirection, includeDeletes: Bool) async {
        guard let profile = selectedProfile, let rsync = rsyncInfo else { return }
        // Bewusst der aufgeloeste Stand: `status` allein weiss nichts davon,
        // dass die Gegenstelle einen Gleichstand schon entschieden hat.
        let current = resolvedStatus
        let expected = current?.itemCount(for: direction) ?? 0
        // Was auf der Empfaengerseite neu ist, darf --delete nicht wegraeumen.
        let protectedPaths =
            direction == .pull
            ? (current?.protectedOnPull ?? []) : (current?.protectedOnPush ?? [])

        // Ein Prozess arbeitet gleich mit dem Profil; ungespeicherte
        // Aenderungen daran waeren eine Falle.
        flushSave()
        phase = .transferring(direction)
        notice = nil
        lastBackup = nil
        progress = TransferProgress(completed: 0, total: expected, currentPath: "")
        runner.resetCancellation()
        await awaitPassword()

        do {
            let outcome = try await engine.transfer(
                profile: profile,
                password: password,
                direction: direction,
                includeDeletes: includeDeletes,
                // Was die Ruecksprache angekuendigt hat. Der Lauf bricht ab,
                // wenn wesentlich mehr zum Loeschen ansteht: wer "17 Dateien
                // löschen?" bestaetigt hat, hat nicht hundert erlaubt.
                expectedDeletions: includeDeletes
                    ? (direction == .pull
                        ? current?.deletionsOnPull.count : current?.deletionsOnPush.count)
                    : nil,
                protectedPaths: includeDeletes ? protectedPaths : [],
                expectedItems: expected,
                gitUnits: current?.gitUnits ?? [],
                remotePaths: current?.remotePaths ?? [],
                localPaths: current?.localPaths ?? [],
                checkedAt: current?.checkedAt,
                rsyncPath: rsync.path,
                // openrsync vertraegt Sicherung und Loeschen nicht zusammen.
                supportsBackupWhileDeleting: !rsync.isOpenRsync,
                inventoryComplete: current?.inventoryComplete ?? true,
                // Genau die Pfade, die die Pruefung dieser Richtung zugeordnet
                // hat. Konflikte stehen in keiner der beiden Listen und bleiben
                // deshalb liegen, statt einseitig ueberschrieben zu werden.
                transferPaths: current?.transferPaths(for: direction),
                onLog: { [weak self] line in
                    Task { @MainActor in self?.append(line) }
                },
                onProgress: { [weak self] value in
                    Task { @MainActor in self?.progress = value }
                }
            )
            phase = .idle
            progress = nil
            // Die Gegenstelle ist das führende System: erst jetzt, wenn die
            // Dateien liegen, wird gegen sie abgeglichen.
            await reconcileRepositories(quiet: true)
            // Erst neu prüfen, dann melden: check() räumt notice ab.
            await check()
            notice = "\(direction.label) abgeschlossen: \(outcome.items.count) Einträge."
        } catch RsyncError.cancelled {
            phase = .idle
            progress = nil
            notice = "Abgebrochen."
        } catch {
            phase = .failed(error.localizedDescription)
            progress = nil
        }
    }

    func cancel() {
        processRunner.cancel()
        append("Abbruch angefordert …")
    }

    // MARK: - Abgleich mit der Gegenstelle

    /// Steht ein Repo an, das sich gegen seine Gegenstelle abgleichen lässt?
    var canReconcileRepositories: Bool {
        gitInfo != nil && !(status?.localPaths.isEmpty ?? true)
    }

    /// Holt je Repo den Stand der Gegenstelle und spult vor, soweit das ohne
    /// Zusammenführen geht.
    ///
    /// `quiet` unterdrückt nur die Meldung: nach einer Übertragung steht dort
    /// schon, wie viele Einträge gewandert sind, und zwei Meldungen
    /// hintereinander überschreiben sich.
    func reconcileRepositories(quiet: Bool = false) async {
        guard let profile = selectedProfile, let rsync = rsyncInfo, let git = gitInfo else {
            if !quiet { notice = "Kein git gefunden. Ohne git gibt es hier nichts abzugleichen." }
            return
        }
        let roots = GitRepositories.roots(in: status?.localPaths ?? [])
        guard !roots.isEmpty else {
            if !quiet { notice = "Im Stammordner liegt kein Git-Repo." }
            return
        }
        guard !profile.backupDestination.isEmpty else {
            if !quiet {
                notice = "Ohne Zielordner für Sicherungen wird nichts angefasst. "
                    + "In den Einstellungen unter „Backup“ einen wählen."
            }
            return
        }

        // Eigener Name: `engine` ist in dieser Klasse die Sync-Maschine.
        let backup = backupEngine
        let sync = GitSync(
            runner: GitCommandRunner(gitPath: git.path),
            // Ohne Sicherung kein Eingriff: wirft das hier, bleibt das Repo,
            // wie es ist, und der Fehlschlag steht in der Zeile des Repos.
            snapshot: { root in
                try await backup.snapshotRepository(
                    root: root, profile: profile, rsyncPath: rsync.path
                ).archive
            }
        )
        phase = .reconciling(done: 0, total: roots.count, name: "")
        let results = await sync.run(
            roots: roots,
            localRoot: profile.localRoot,
            onLog: { [weak self] line in
                Task { @MainActor in self?.append(line) }
            },
            onProgress: { [weak self] done, total, name in
                Task { @MainActor in
                    self?.phase = .reconciling(done: done, total: total, name: name)
                }
            }
        )
        gitResults = Dictionary(uniqueKeysWithValues: results.map { ($0.root, $0) })
        // Nur zuruecksetzen, wenn wir die Phase auch gesetzt haben: Nach einer
        // Uebertragung laeuft das hier im Anschluss, und dort soll der Ablauf
        // weiterlaufen, statt an dieser Stelle auf "fertig" zu springen.
        if case .reconciling = phase { phase = .idle }

        let summary = GitSync.summary(of: results)
        if !quiet {
            notice = summary
        } else {
            append(summary)
        }
    }

    // MARK: - Backup

    var backupReady: Bool {
        guard let profile = selectedProfile else { return false }
        return !profile.backupDestination.isEmpty && !profile.localRoot.isEmpty
    }

    var backupHint: String {
        guard let profile = selectedProfile else { return "Kein Profil gewählt." }
        if profile.localRoot.isEmpty { return "Kein lokaler Stammordner gewählt." }
        if profile.backupDestination.isEmpty {
            return "Kein Zielordner für Backups gewählt. In den Einstellungen eintragen."
        }
        return "Packt \(profile.localRoot) in ein Zip-Archiv."
    }

    func backup(ignoreSpace: Bool = false) async {
        guard let profile = selectedProfile, let rsync = rsyncInfo else {
            notice = rsyncWarning
            return
        }
        // Ein Prozess arbeitet gleich mit dem Profil; ungespeicherte
        // Aenderungen daran waeren eine Falle.
        flushSave()
        phase = .backingUp
        notice = nil
        lastBackup = nil
        progress = nil
        clearLog()
        processRunner.resetCancellation()

        do {
            let result = try await backupEngine.run(
                profile: profile,
                rsyncPath: rsync.path,
                ignoreSpace: ignoreSpace,
                onLog: { [weak self] line in
                    Task { @MainActor in self?.append(line) }
                },
                onProgress: { [weak self] value in
                    Task { @MainActor in self?.progress = value }
                }
            )
            phase = .idle
            progress = nil
            lastBackup = result
            append(
                "Fertig: \(result.entryCount) Einträge in \(result.archive.lastPathComponent)."
            )
        } catch ProcessRunnerError.cancelled {
            phase = .idle
            progress = nil
            notice = "Abgebrochen."
        } catch {
            phase = .failed(error.localizedDescription)
            progress = nil
        }
    }

    func revealLastBackup() {
        guard let archive = lastBackup?.archive else { return }
        NSWorkspace.shared.activateFileViewerSelecting([archive])
    }

    // MARK: - Protokoll

    func append(_ line: String) {
        log.append(line)
        if log.count > logLimit { log.removeFirst(log.count - logLimit) }
        // Und in die Datei, damit ein Lauf, der die App mitnimmt, eine Spur
        // hinterlaesst. Im Fenster steht das Protokoll nur, solange die App
        // laeuft, und genau dann ist es weg, wenn man es braucht.
        runLog.write(line)
    }

    func clearLog() {
        log.removeAll()
        // Die Datei nicht: Sie ist fuer den Fall da, dass jemand hinterher
        // nachsehen will, und ein neuer Lauf loescht die Spur des vorigen nicht.
        runLog.write("--- neuer Lauf ---")
    }

    // MARK: - Anzeige in der Menüleiste

    var menuBarSymbol: String {
        switch phase {
        case .checking, .transferring: return "arrow.triangle.2.circlepath"
        case .reconciling: return "arrow.triangle.branch"
        case .backingUp: return "archivebox"
        case .failed: return "xmark.octagon"
        case .idle:
            guard let status else { return "arrow.triangle.2.circlepath" }
            if !status.conflicts.isEmpty { return "exclamationmark.triangle" }
            return status.isInSync ? "checkmark.circle" : "exclamationmark.circle"
        }
    }
}
