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
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .transferring, .backingUp: return true
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
    private let stateStore = SyncStateStore()
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
        Task { await refreshRsync(preferred: selectedProfile?.rsyncPath ?? "") }
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

    func loadPassword() {
        guard let profile = selectedProfile, !profile.host.isEmpty, !profile.user.isEmpty else {
            password = ""
            return
        }
        password =
            (try? keychain.load(host: profile.host, port: profile.port, account: profile.user))
            ?? ""
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
            testFolder(profile: profile)
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
    private func testFolder(profile: Profile) {
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
        settingsNotice =
            "Zielordner ist da und beschreibbar, \(count) "
            + (count == 1 ? "Eintrag" : "Einträge") + " direkt darin."
        append(settingsNotice!)
    }

    private func testSSH(profile: Profile, password: String) async {
        append("Verbinde mit \(profile.user)@\(profile.host):\(profile.port) …")
        do {
            let session = try SSHSession(profile: profile)
            defer { session.stop() }
            try session.start(password: password)
            let result = try await session.testConnection()
            if result.succeeded {
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
        let expected =
            direction == .pull
            ? (status?.incoming.count ?? 0) : (status?.outgoing.count ?? 0)
        // Was auf der Empfaengerseite neu ist, darf --delete nicht wegraeumen.
        let protectedPaths =
            direction == .pull
            ? (status?.protectedOnPull ?? []) : (status?.protectedOnPush ?? [])

        // Ein Prozess arbeitet gleich mit dem Profil; ungespeicherte
        // Aenderungen daran waeren eine Falle.
        flushSave()
        phase = .transferring(direction)
        notice = nil
        lastBackup = nil
        progress = TransferProgress(completed: 0, total: expected, currentPath: "")
        runner.resetCancellation()

        do {
            let outcome = try await engine.transfer(
                profile: profile,
                password: password,
                direction: direction,
                includeDeletes: includeDeletes,
                protectedPaths: includeDeletes ? protectedPaths : [],
                expectedItems: expected,
                remotePaths: status?.remotePaths ?? [],
                localPaths: status?.localPaths ?? [],
                rsyncPath: rsync.path,
                onLog: { [weak self] line in
                    Task { @MainActor in self?.append(line) }
                },
                onProgress: { [weak self] value in
                    Task { @MainActor in self?.progress = value }
                }
            )
            phase = .idle
            progress = nil
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
    }

    func clearLog() { log.removeAll() }

    // MARK: - Anzeige in der Menüleiste

    var menuBarSymbol: String {
        switch phase {
        case .checking, .transferring: return "arrow.triangle.2.circlepath"
        case .backingUp: return "archivebox"
        case .failed: return "xmark.octagon"
        case .idle:
            guard let status else { return "arrow.triangle.2.circlepath" }
            if !status.conflicts.isEmpty { return "exclamationmark.triangle" }
            return status.isInSync ? "checkmark.circle" : "exclamationmark.circle"
        }
    }
}
