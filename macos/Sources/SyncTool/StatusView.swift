import SwiftUI
import SyncCore

struct StatusView: View {

    /// Wie die andere Seite in dieser Ansicht heisst. "Server" ist bei einer
    /// externen Platte falsch, und "Vom Server holen" ueber einem Ordner auf der
    /// eigenen Platte erklaert niemandem, was passiert.
    private var remoteLabel: String {
        state.selectedProfile?.transport.remoteLabel ?? "Ziel"
    }
    private var remoteLabelInPlace: String {
        state.selectedProfile?.transport.remoteLabelInPlace ?? "im Ziel"
    }
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    /// Sagt dem Anker, in welchem Fenster diese Ansicht steckt. Nur die
    /// Menueleiste setzt das; das eigene Statusfenster soll nirgends andocken.
    var windowKeeper: MenuBarWindowKeeper?

    /// Ab hier scrollt der Mittelteil, statt das Fenster weiter wachsen zu
    /// lassen. `nil` heisst: unbegrenzt, das Fenster waechst mit.
    ///
    /// Siehe `MenuBarGeometry.maxContentHeight`.
    var maxContentHeight: CGFloat?

    @State private var showLog = false
    @State private var deleteOnTransfer = false
    @State private var pendingDeletion: PendingDeletion?

    private struct PendingDeletion: Identifiable {
        let id = UUID()
        let direction: SyncDirection
        let items: [ChangeItem]
    }

    /// Seitlicher Einzug fuer alle Inhalte. Die Trennlinien laufen bewusst
    /// darunter durch: eine eingerueckte Trennlinie franst den rechten Rand aus.
    private let inset: CGFloat = 16

    /// Bewusst ohne jeden Hoehenzwang, mit genau einer Ausnahme.
    ///
    /// `MenuBarExtra` im Fenster-Stil richtet die Fensterhoehe nach der
    /// Wunschgroesse dieser Ansicht. Jede feste oder auch nur mindestgesetzte
    /// Hoehe im Inneren macht diese Wunschgroesse mehrdeutig; das Fenster
    /// bleibt dann zu klein, der Stapel staucht seine Kinder, und Kopfzeile,
    /// Inhalt und Fusszeile zeichnen uebereinander.
    ///
    /// Die Ausnahme ist eine Obergrenze fuer den Mittelteil, und sie ist der
    /// Grund, warum das Fenster nicht mehr wandert. Es waechst nach unten, wenn
    /// ein Abschnitt aufgeht, und schrumpft wieder, wenn er zugeht. Nur ueber
    /// den Bildschirmrand hinaus waechst es nicht mehr, denn ab dort rueckt
    /// macOS es nach oben weg und beim Zuklappen nicht zurueck.
    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, inset)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()

            banners

            scrollingContent

            Divider()

            footer
                .padding(.horizontal, inset)
                .padding(.vertical, 10)
        }
        .frame(width: 460)
        // Undurchsichtiger Grund, und zwar aus einem sachlichen Grund: Ueber
        // einer durchscheinenden Unterlage schaltet AppKit die Schriftglaettung
        // ab, Text wird duenn und ausgefranst. Das faellt bei einem Fenster
        // voller Zahlen sofort auf. Nebenbei liest sich eine Tabelle besser,
        // wenn nicht der Schreibtisch durchscheint.
        //
        // Wer den milchigen Fensterhintergrund lieber mag: diese Zeile durch
        // `.background(.thickMaterial)` ersetzen und die weichere Schrift
        // in Kauf nehmen.
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            if let windowKeeper {
                MenuBarWindowReporter(keeper: windowKeeper)
            }
        }
        .onChange(of: state.selectedProfileID) { _, _ in
            // Beide haengen am Profil: ein fuer A gesetzter Haken darf nach dem
            // Umschalten auf B nicht stehen bleiben, B erlaubt womoeglich gar
            // kein Loeschen.
            deleteOnTransfer = false
            pendingDeletion = nil
        }
    }

    /// Der Mittelteil. Vor der ersten Pruefung so hoch wie sein Inhalt, danach
    /// mit fester Hoehe und Bildlauf.
    ///
    /// Die Entscheidung haengt bewusst an den Daten und nicht am Layout. Der
    /// Anlauf davor hat die natuerliche Hoehe gemessen und daraufhin
    /// umgeschaltet. Im eigenen Fenster ging das, im Popover der Menueleiste
    /// nicht: Das gehoert unter macOS 26 zu einem anderen Prozess, und der
    /// zweite Durchgang, in dem die Messung erst wirksam wird, kam dort nie an.
    /// Das Fenster blieb in der ungebremsten Fassung stehen und wuchs auf ueber
    /// 1600 Punkt.
    ///
    /// Was hier entschieden wird, steht deshalb vor dem ersten Zeichnen fest:
    /// Gibt es ein Pruefergebnis, ist der Mittelteil genau `maxContentHeight`
    /// hoch. Gibt es keins, hat er fast nichts anzuzeigen, und dann waere eine
    /// feste Hoehe nur ein grosses leeres Fenster.
    ///
    /// Ein Rollbalken erscheint dabei nur, wenn der Inhalt wirklich laenger
    /// ist. Ein volles Pruefergebnis mit zugeklappten Abschnitten passt.
    @ViewBuilder
    private var scrollingContent: some View {
        let inner =
            content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inset)
            .padding(.vertical, 12)

        if let grenze = maxContentHeight, state.status != nil {
            ScrollView {
                inner
            }
            .frame(height: grenze)
            // Kurze Inhalte sollen nicht federn: Das sieht nach Fehler aus.
            .scrollBounceBehavior(.basedOnSize)
        } else {
            inner
        }
    }

    // MARK: - Kopf

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("SyncTool")
                    .font(.headline)

                // Fassung und Baunummer sichtbar, nicht nur im Mauszeiger-Hinweis:
                // Genau dafuer sind sie da, den Stand zweier Rechner zu vergleichen.
                Text(AppVersion.display)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Spacer(minLength: 12)

                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "settings")
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Einstellungen")
            }

            // Links buendig in seiner natuerlichen Breite. Ein `Picker` laesst
            // sich auf macOS nicht dehnen; ohne Ausrichtung setzt ihn SwiftUI
            // mittig, und dann steht er quer zu allem anderen.
            if !state.profiles.isEmpty {
                Picker("", selection: profileBinding) {
                    ForEach(state.profiles) { profile in
                        Text(profile.name.isEmpty ? "Ohne Namen" : profile.name).tag(profile.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var profileBinding: Binding<UUID> {
        Binding(
            get: { state.selectedProfileID ?? state.profiles.first?.id ?? UUID() },
            set: { state.selectProfile($0) }
        )
    }

    /// Waehrend der Pruefung haben sich Dateien bewegt.
    ///
    /// Ohne diesen Hinweis stuende im Statusfenster schlicht nichts zum
    /// Loeschen, und der Nutzer wuesste nicht, ob es nichts zu loeschen gibt
    /// oder ob die App die Frage nicht beantworten konnte. Das ist ein
    /// Unterschied, der ihn etwas angeht.
    private var incompleteInventoryNotice: String? {
        guard let status = state.resolvedStatus, !status.inventoryComplete else { return nil }
        return "Während der Prüfung haben sich Dateien bewegt, die Bestandsliste ist "
            + "deshalb unvollständig. Übertragen geht, gelöscht wird auf dieser Grundlage "
            + "nichts: Eine Datei, die beim Auflisten verschwand, sieht genauso aus wie "
            + "eine gelöschte. Noch einmal prüfen."
    }

    /// Wer zuletzt gegen dieses Ziel gelaufen ist.
    ///
    /// Die Frage, die man sich bei mehreren Rechnern wirklich stellt: Ist mein
    /// Stand der aktuelle, oder hat inzwischen jemand anders gearbeitet? Ohne
    /// diese Zeile lässt sie sich aus dem Fenster nicht beantworten.
    private var remoteRunNotice: String? {
        guard let run = state.resolvedStatus?.lastRemoteRun else { return nil }
        return "Zuletzt abgeglichen von \(run.machine), \(Format.timestamp(run.at))."
    }

    @ViewBuilder
    private var banners: some View {
        let warning = state.rsyncWarning
        let notice = state.notice
        let remoteRun = remoteRunNotice
        let incomplete = incompleteInventoryNotice
        let failure: String? = {
            if case .failed(let message) = state.phase { return message }
            return nil
        }()

        if warning != nil || notice != nil || remoteRun != nil || incomplete != nil
            || failure != nil
        {
            VStack(alignment: .leading, spacing: 6) {
                if let warning { Banner(text: warning, kind: .warning) }
                if let notice { Banner(text: notice, kind: .info) }
                if let remoteRun { Banner(text: remoteRun, kind: .info) }
                if let incomplete { Banner(text: incomplete, kind: .warning) }
                if let failure { Banner(text: failure, kind: .error) }
            }
            .padding(.horizontal, inset)
            .padding(.top, 10)
        }
    }

    // MARK: - Inhalt

    @ViewBuilder
    private var content: some View {
        if let pending = pendingDeletion {
            deletionConfirmation(pending)
        } else if let progress = state.progress {
            transferProgress(progress)
        } else if state.phase == .backingUp {
            // Solange der Bestand aufgenommen wird, ist die Gesamtzahl unbekannt.
            VStack(alignment: .leading, spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Bestand aufnehmen …")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if case .reconciling(let done, let total, let name) = state.phase {
            // Jedes Repo kostet ein `fetch` ueber das Netz. Ohne Zaehler sieht
            // es aus, als passiere nichts, und bei zwanzig Repos dauert das
            // Minuten.
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                Text(
                    name.isEmpty
                        ? "Repos mit der Gegenstelle abgleichen …"
                        : "\(name) · \(done) von \(total)"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                Text("Für jedes Repo wird einmal beim Anbieter nachgefragt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let backup = state.lastBackup {
            backupResult(backup)
        } else if let status = state.resolvedStatus {
            result(for: status)
        } else if state.selectedProfile == nil {
            VStack(alignment: .leading, spacing: 4) {
                Text("Kein Profil angelegt")
                    .font(.callout.weight(.medium))
                Text("In den Einstellungen ein Sync-Ziel anlegen: Server, Ordner und Anmeldung.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Noch nicht geprüft")
                    .font(.callout.weight(.medium))
                Text("„Prüfen“ vergleicht beide Seiten und zeigt, was auseinanderläuft.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func result(for status: SyncStatus) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            statusHeader(status)

            GitSection(
                remoteLabel: remoteLabel,
                units: status.gitUnits,
                results: state.gitResults
            )

            if !status.isInSync {
                VStack(alignment: .leading, spacing: 8) {
                    if !status.conflicts.isEmpty {
                        ConflictSection(remoteLabel: remoteLabel, conflicts: status.conflicts)
                    }
                    DriftSection(
                        title: "Vom \(remoteLabel) holen",
                        systemImage: "arrow.down.circle",
                        items: status.incoming,
                        bytes: status.incomingBytes
                    )
                    DriftSection(
                        title: "Zum \(remoteLabel) schicken",
                        systemImage: "arrow.up.circle",
                        items: status.outgoing,
                        bytes: status.outgoingBytes
                    )
                }
            }

            InventoryBalance(remoteLabel: remoteLabel, report: status.report)

            deletionRow(status)
            actions(status)
        }
    }

    /// Ein Anker statt zweier an die Raender gespreizter Zeitangaben: Symbol,
    /// Urteil, darunter das Beilaeufige. Alle Texte beginnen an derselben Stelle.
    private func statusHeader(_ status: SyncStatus) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol(for: status))
                .font(.title3)
                .foregroundStyle(color(for: status))

            VStack(alignment: .leading, spacing: 2) {
                Text(headline(for: status))
                    .font(.callout.weight(.medium))
                Text(
                    "Geprüft \(Format.relative(status.checkedAt)) · "
                        + "letzter Abgleich \(Format.relative(status.lastSync))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    /// Ein Repo, das auseinanderlaeuft, wiegt so schwer wie ein Dateikonflikt:
    /// in beiden Faellen muss jemand entscheiden.
    private func diverged(_ status: SyncStatus) -> Int {
        status.gitUnits.count { $0.state == .conflict }
    }

    private func symbol(for status: SyncStatus) -> String {
        if !status.conflicts.isEmpty || diverged(status) > 0 {
            return "exclamationmark.triangle.fill"
        }
        return status.isInSync ? "checkmark.circle.fill" : "arrow.left.arrow.right.circle.fill"
    }

    private func color(for status: SyncStatus) -> Color {
        if !status.conflicts.isEmpty || diverged(status) > 0 { return .orange }
        return status.isInSync ? .green : .accentColor
    }

    private func headline(for status: SyncStatus) -> String {
        if !status.conflicts.isEmpty {
            return Format.count(
                status.conflicts.count, singular: "Konflikt", plural: "Konflikte"
            )
        }
        if diverged(status) > 0 {
            return Format.count(
                diverged(status), singular: "Repo läuft", plural: "Repos laufen"
            ) + " auseinander"
        }
        if status.isInSync { return "Alles auf gleichem Stand" }
        let offen = status.incoming.count + status.outgoing.count
            + status.deletionsOnPull.count + status.deletionsOnPush.count
            + status.gitUnits.count { $0.state != .settled }
        return Format.count(offen, singular: "Unterschied", plural: "Unterschiede")
    }

    private func backupResult(_ result: BackupResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "archivebox.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.archive.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(
                        "\(Format.count(result.entryCount, singular: "Eintrag", plural: "Einträge")) · "
                            + "\(Format.bytes(result.rawBytes)) → \(Format.bytes(result.archiveBytes)) · "
                            + "\(Int(result.duration.rounded())) s"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if !result.missing.isEmpty {
                Banner(
                    text: "\(Format.number(result.missing.count)) Einträge fehlen im Archiv. "
                        + "Das Protokoll nennt sie.",
                    kind: .warning
                )
            }

            HStack(spacing: 10) {
                Button("Im Finder zeigen") { state.revealLastBackup() }
                    .frame(maxWidth: .infinity)
                Button("Zurück") { state.lastBackup = nil }
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
        }
    }

    private func transferProgress(_ progress: TransferProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: progress.fraction)
            HStack {
                Text("\(Format.number(progress.completed)) von \(Format.number(max(progress.total, progress.completed)))")
                Spacer()
                Text("\(Int(progress.fraction * 100)) %")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            Text(progress.currentPath)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func deletionRow(_ status: SyncStatus) -> some View {
        let pull = status.deletionsOnPull.count
        let push = status.deletionsOnPush.count
        if pull > 0 || push > 0 {
            VStack(alignment: .leading, spacing: 4) {
                if state.selectedProfile?.deleteAllowed == true {
                    Toggle(isOn: $deleteOnTransfer) {
                        Text("Löschungen mitziehen")
                    }
                    .toggleStyle(.checkbox)
                } else {
                    Text("Löschen ist für dieses Profil in den Einstellungen ausgeschaltet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if push > 0 {
                    Text(
                        "\(Format.count(push, singular: "Datei hast", plural: "Dateien hast")) "
                            + "du lokal gelöscht. Hochladen entfernt sie auch \(remoteLabelInPlace)."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if pull > 0 {
                    Text(
                        "\(Format.count(pull, singular: "Datei wurde", plural: "Dateien wurden")) "
                            + "\(remoteLabelInPlace) gelöscht. Herunterladen entfernt sie auch hier."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func actions(_ status: SyncStatus) -> some View {
        transferActions(status)
        untouchedNote(status)
        if state.canReconcileRepositories {
            Button {
                Task { await state.reconcileRepositories() }
            } label: {
                Label("Repos mit der Gegenstelle abgleichen", systemImage: "arrow.triangle.branch")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            // Sonst laesst sich der Abgleich ein zweites Mal anstossen,
            // waehrend der erste noch laeuft.
            .disabled(state.phase.isBusy)
            .disabled(state.phase.isBusy)
        }
    }

    /// Was ein Lauf in dieser Richtung stehen laesst.
    ///
    /// Die Zahl am Knopf zaehlt nur, was tatsaechlich hinuebergeht. Ohne diese
    /// Zeile koennte man meinen, "Hochladen" raeume alles ab, was oben in der
    /// Liste steht. Es tut weniger, und das ist der Punkt.
    @ViewBuilder
    private func untouchedNote(_ status: SyncStatus) -> some View {
        if !status.conflicts.isEmpty {
            Text(
                "\(Format.count(status.conflicts.count, singular: "Konflikt bleibt", plural: "Konflikte bleiben")) "
                    + "in diesem Lauf unberührt. Beide Fassungen bleiben, wo sie sind, "
                    + "bis du entscheidest."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func transferActions(_ status: SyncStatus) -> some View {
        HStack(spacing: 10) {
            transferButton(
                title: "Herunterladen", symbol: "arrow.down.circle",
                count: status.itemCount(for: .pull), deletions: planned(status.deletionsOnPull),
                shortcut: .downArrow
            ) { start(.pull, deletions: status.deletionsOnPull) }

            transferButton(
                title: "Hochladen", symbol: "arrow.up.circle",
                count: status.itemCount(for: .push), deletions: planned(status.deletionsOnPush),
                shortcut: .upArrow
            ) { start(.push, deletions: status.deletionsOnPush) }
        }
        .controlSize(.large)
        .buttonStyle(.bordered)
    }

    /// Fester Titel, Anzahl als schmale Plakette.
    ///
    /// Eine mitwachsende Beschriftung wie "(3 + 2 Loeschungen)" sprengt die
    /// halbe Fensterbreite und kuerzt dann mitten im Wort. Die Zahl der
    /// Loeschungen steht ohnehin eine Zeile darueber.
    private func transferButton(
        title: String, symbol: String, count: Int, deletions: Int,
        shortcut: KeyEquivalent, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
                if count + deletions > 0 {
                    Text(Format.number(count + deletions))
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.2), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity)
        }
        .keyboardShortcut(shortcut, modifiers: .command)
        .disabled(count + deletions == 0 || state.phase.isBusy)
    }

    /// Was der Lauf wirklich löschen würde. Ohne Haken und ohne Erlaubnis im
    /// Profil passiert nichts, dann darf der Knopf es auch nicht ankündigen.
    private func planned(_ deletions: [ChangeItem]) -> Int {
        guard deleteOnTransfer, state.selectedProfile?.deleteAllowed == true else { return 0 }
        return deletions.count
    }

    private func start(_ direction: SyncDirection, deletions: [ChangeItem]) {
        if deleteOnTransfer && !deletions.isEmpty {
            pendingDeletion = PendingDeletion(direction: direction, items: deletions)
        } else {
            Task { await state.transfer(direction, includeDeletes: false) }
        }
    }

    /// Bewusst im Popover statt als eigenes Fenster: Ein `MenuBarExtra` im
    /// Fenster-Stil schliesst sich, sobald ein Alert die Tastaturfuehrung
    /// uebernimmt, und nimmt den Alert mit. Die Rueckfrage war so nicht zu
    /// bestaetigen.
    private func deletionConfirmation(_ pending: PendingDeletion) -> some View {
        let side = pending.direction == .pull ? "hier" : remoteLabelInPlace
        return VStack(alignment: .leading, spacing: 10) {
            Label(
                "\(Format.count(pending.items.count, singular: "Datei", plural: "Dateien")) löschen?",
                systemImage: "trash"
            )
            .font(.headline)
            .foregroundStyle(.red)

            Text("Diese Dateien werden \(side) entfernt. Das lässt sich nicht rückgängig machen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Ohne eigene Scrollflaeche: die aeussere scrollt schon, und zwei
            // ineinanderliegende Scrollflaechen sind auf macOS eine Zumutung.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(pending.items.prefix(200)) { item in
                    Text(item.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if pending.items.count > 200 {
                    Text("… und \(Format.number(pending.items.count - 200)) weitere")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 10) {
                Button("Abbrechen") { pendingDeletion = nil }
                    .keyboardShortcut(.cancelAction)
                    .frame(maxWidth: .infinity)
                Button(role: .destructive) {
                    pendingDeletion = nil
                    Task { await state.transfer(pending.direction, includeDeletes: true) }
                } label: {
                    Text("Löschen und \(pending.direction.label.lowercased())")
                        .frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Fuß

    /// Zwei Raenge: umrandet und gleich breit links sind die Hauptaktionen,
    /// randlos und gedaempft rechts die Nebensachen. Der Rang kommt aus dem
    /// Stil, die Stellung folgt ihm nur.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if state.phase.isBusy {
                    Button("Abbrechen", role: .cancel) { state.cancel() }
                        .frame(minWidth: 104)
                        .buttonStyle(.bordered)
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await state.check() }
                    } label: {
                        Label("Prüfen", systemImage: "arrow.triangle.2.circlepath")
                            .frame(minWidth: 104)
                    }
                    .keyboardShortcut("r")
                    .buttonStyle(.bordered)
                    .disabled(state.selectedProfile == nil)

                    // Bewusst hier und nicht bei den Übertragungsknöpfen: die
                    // setzen ein Prüfergebnis voraus, ein Backup nicht.
                    Button {
                        Task { await state.backup() }
                    } label: {
                        Label("Backup", systemImage: "archivebox")
                            .frame(minWidth: 104)
                    }
                    .keyboardShortcut("b")
                    .buttonStyle(.bordered)
                    .disabled(!state.backupReady)
                    .help(state.backupHint)
                }

                Spacer(minLength: 20)

                Button(showLog ? "Protokoll ausblenden" : "Protokoll") { showLog.toggle() }
                    .help("Das vollständige Protokoll liegt in \(AppPaths.runLogPath)")
                Button("Beenden") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)

            if showLog {
                LogView(lines: state.log)
            }
        }
    }
}

// MARK: - Bausteine

private struct InventoryBalance: View {
    let remoteLabel: String
    let report: InventoryReport
    @State private var excludedExpanded = false
    @State private var settledExpanded = false
    @State private var restExpanded = false

    /// Gemessen an den Zahlen, die dastehen, nicht an den rohen.
    private var differs: Bool {
        report.remoteFilesOutsideSettled != report.localFilesOutsideSettled
            || report.remoteDirectoriesOutsideSettled != report.localDirectoriesOutsideSettled
    }

    /// Orange nur, wenn der Unterschied offen ist. Liegt er ganz in Repos auf
    /// gleichem Stand, ist er erklaert, und ein Warnton daneben widerspraeche
    /// dem gruenen Haken darueber.
    private var unexplained: Bool { report.hasUnexplainedEntries }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                side(
                    remoteLabel, report.remoteFilesOutsideSettled,
                    report.remoteDirectoriesOutsideSettled, report.remoteBytes
                )
                Image(systemName: differs ? "notequal" : "equal")
                    .font(.caption)
                    .foregroundStyle(unexplained ? Color.orange : Color.secondary.opacity(0.6))
                    .padding(.top, 18)
                side(
                    "Lokal", report.localFilesOutsideSettled,
                    report.localDirectoriesOutsideSettled, report.localBytes
                )
            }

            if report.settledRepositories > 0 { settledNote }
            if unexplained { rest }
            if report.excludedCount > 0 { excluded }
        }
    }

    /// Die Antwort auf "warum steht da ein Haken und trotzdem ein Ungleich".
    ///
    /// Frueher stand hier ein Satz, der das behauptete. Jetzt steht die
    /// Rechnung daneben: je Repo die Zahl beider Seiten und die Differenz mit
    /// Vorzeichen. Die Zeilen addieren sich zu der Zahl, die oben steht, und
    /// damit laesst sich die Aussage nachrechnen statt glauben.
    private var settledNote: some View {
        DisclosureGroup(isExpanded: $settledExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(report.settledContributors) { repo in
                            HStack(spacing: 6) {
                                Text(repo.displayName)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(
                                    "\(remoteLabel) \(Format.number(repo.remote)) · "
                                        + "lokal \(Format.number(repo.local)) · "
                                        + (repo.difference > 0 ? "+" : "")
                                        + "\(repo.difference)"
                                )
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                Text(
                    "Dieselben Commits, anders gepackt: git benennt seine Packdateien nach "
                        + "ihrem Inhalt und packt von sich aus um. Ein Repo auf gleichem "
                        + "Stand ist deshalb eine Einheit und kein Haufen Dateien, und es "
                        + "zählt oben nicht mit."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

                // Die rohen Summen bleiben erreichbar: Genau die sieht ein
                // FTP-Client, und genau die will man dagegenhalten können.
                Text(
                    "Roh gezählt, also alles mitgerechnet: \(remoteLabel) "
                        + "\(Format.number(report.remoteFiles)) Dateien · "
                        + "\(Format.number(report.remoteDirectories)) Ordner, lokal "
                        + "\(Format.number(report.localFiles)) Dateien · "
                        + "\(Format.number(report.localDirectories)) Ordner. "
                        + "Das ist die Sicht eines FTP-Clients."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            }
            .padding(.leading, 18)
            .padding(.top, 4)
        } label: {
            Text(
                "\(Format.count(report.settledRepositories, singular: "Repo", plural: "Repos")) "
                    + "auf gleichem Stand, nicht mitgezählt"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Was die Repos nicht erklären.
    ///
    /// Die Beschriftung sagt, was gemessen wurde, und nicht, was daraus folgt:
    /// "N Einträge liegen nur auf einer Seite". Das Wort "erklärt" steht
    /// nirgends, solange hier etwas steht.
    private var rest: some View {
        DisclosureGroup(isExpanded: $restExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(report.unexplained.prefix(200)) { eintrag in
                            HStack(spacing: 6) {
                                Text(eintrag.path)
                                    .font(.caption2.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(eintrag.side == .remote ? "nur \(remoteLabel)" : "nur lokal")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if report.unexplainedCount > 200 {
                            Text(
                                "… und \(Format.number(report.unexplainedCount - 200)) weitere"
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                Text(
                    "Diese Einträge liegen auf genau einer Seite und in keinem Repo auf "
                        + "gleichem Stand. Sie sind der Grund, warum die beiden Zahlen "
                        + "auseinandergehen."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            }
            .padding(.leading, 18)
            .padding(.top, 4)
        } label: {
            Text(
                "\(Format.count(report.unexplainedCount, singular: "Eintrag liegt", plural: "Einträge liegen")) "
                    + "nur auf einer Seite"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    private func side(_ title: String, _ files: Int, _ directories: Int, _ bytes: Int64) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            // Ohne feste Ziffernbreite tanzen sechsstellige Zahlen bei jeder
            // Aktualisierung, und zwei Werte lassen sich nicht vergleichen.
            Text(Format.number(files))
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(unexplained ? Color.orange : .primary)
            Text("\(Format.number(directories)) Ordner · \(Format.bytes(bytes))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var excluded: some View {
        DisclosureGroup(isExpanded: $excludedExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(report.excluded.prefix(100)) { branch in
                    HStack(spacing: 6) {
                        Text(branch.path)
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if branch.count > 1 {
                            Text(Format.number(branch.count))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if report.excluded.count > 100 {
                    Text("… und \(Format.number(report.excluded.count - 100)) weitere Zweige")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(
                    "Kommt aus der Ausschlussliste in den Einstellungen. Genau diese "
                        + "Einträge sieht ein FTP-Client zusätzlich."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            }
            .padding(.leading, 18)
            .padding(.top, 4)
        } label: {
            Text(
                "\(Format.number(report.excludedCount)) Einträge ausgeschlossen · "
                    + "\(Format.number(report.excluded.count)) Zweige"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct DriftSection: View {
    let title: String
    let systemImage: String
    let items: [DriftItem]
    let bytes: Int64

    @State private var expanded = false

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items.prefix(200)) { item in
                        HStack(spacing: 6) {
                            Text(item.path)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(item.reason.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if items.count > 200 {
                        Text("… und \(Format.number(items.count - 200)) weitere")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 18)
                .padding(.top, 4)
            } label: {
                // Richtung links, Menge rechts: dieselbe Achse wie die
                // Bestandsspalten darunter und die Knoepfe daruntersetzen.
                HStack(spacing: 6) {
                    Label(title, systemImage: systemImage)
                    Spacer(minLength: 8)
                    Text(
                        "\(Format.count(items.count, singular: "Datei", plural: "Dateien")) · "
                            + "\(Format.bytes(bytes))"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ConflictSection: View {
    let remoteLabel: String
    let conflicts: [ConflictItem]
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    "Diese Dateien wurden auf beiden Seiten verändert. Kein Lauf fasst sie "
                        + "an: Beide Fassungen bleiben, wo sie sind, bis du entscheidest. "
                        + "Vergleichen, von Hand zusammenführen, dann noch einmal prüfen."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                ForEach(conflicts.prefix(100)) { conflict in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(conflict.path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(
                            "\(conflict.reason.label) · \(remoteLabel) \(Format.timestamp(conflict.remoteModified)) "
                                + "(\(Format.bytes(conflict.remoteSize))) · lokal "
                                + "\(Format.timestamp(conflict.localModified)) (\(Format.bytes(conflict.localSize)))"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                }
            }
            .padding(.leading, 18)
            .padding(.top, 4)
        } label: {
            Label(
                "Konflikte: \(Format.count(conflicts.count, singular: "Datei", plural: "Dateien"))",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
        }
    }
}

/// Ein Repo als eine Zeile, statt tausender `.git`-Pfade.
///
/// Gespeist aus zwei Quellen: der Abweichung zum Sync-Ziel und dem Abgleich mit
/// der Gegenstelle. Beides einzeln reicht nicht. Ein Repo kann zum Sync-Ziel
/// passen und trotzdem hinter seiner Gegenstelle haengen, und dann stand hier
/// vorher gar nichts.
private struct GitSection: View {
    let remoteLabel: String
    let units: [GitUnit]
    /// Was der Abgleich mit der Gegenstelle ergeben hat, je Repo-Stamm.
    let results: [String: GitRepoResult]
    @State private var expanded = true

    struct Row: Identifiable {
        var id: String { root }
        let root: String
        let unit: GitUnit?
        let result: GitRepoResult?

        var displayName: String { root.isEmpty ? "Stammordner" : String(root.dropLast()) }
    }

    /// Nur was eine Handlung oder eine Erklaerung braucht. Ein Repo, das zum
    /// Sync-Ziel passt und auf dem Stand seiner Gegenstelle steht, gehoert
    /// nicht in eine Liste, in der nichts zu tun ist.
    private var rows: [Row] {
        let byRoot = Dictionary(
            units.filter { $0.state != .settled }.map { ($0.root, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let roots = Set(byRoot.keys).union(results.filter(\.value.needsAttention).keys)
        return roots.sorted().map { Row(root: $0, unit: byRoot[$0], result: results[$0]) }
    }

    private var diverged: Int { units.count { $0.state == .conflict } }

    var body: some View {
        if !rows.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        "Ein Repo geht als Ganzes über, .git eingeschlossen. Läuft es auf beiden "
                            + "Seiten auseinander, bleibt es in diesem Lauf unberührt: ein halb "
                            + "übertragenes .git ist schlimmer als ein veraltetes."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(rows) { row in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.displayName)
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(detail(for: row))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                }
                .padding(.leading, 18)
                .padding(.top, 4)
            } label: {
                Label(
                    "Git-Repos: \(Format.number(rows.count))",
                    systemImage: "arrow.triangle.branch"
                )
                .foregroundStyle(diverged > 0 ? Color.orange : Color.primary)
            }
        }
    }

    private func detail(for row: Row) -> String {
        var parts: [String] = []
        switch row.unit?.state {
        case .incoming:
            parts.append(
                "vom \(remoteLabel) holen, "
                    + Format.count(
                        row.unit?.itemCount ?? 0, singular: "Eintrag", plural: "Einträge"
                    )
            )
        case .outgoing:
            parts.append(
                "zum \(remoteLabel) schicken, "
                    + Format.count(
                        row.unit?.itemCount ?? 0, singular: "Eintrag", plural: "Einträge"
                    )
            )
        case .conflict:
            parts.append(
                "läuft auseinander: \(row.unit?.incomingCount ?? 0) \(remoteLabel), "
                    + "\(row.unit?.outgoingCount ?? 0) hier"
            )
        case .settled:
            // Steht hier nur, falls die Zeile es doch bis hierher schafft:
            // `rows` nimmt gleichstehende Repos gar nicht erst auf.
            parts.append("gleicher Stand wie auf dem \(remoteLabel)")
        case nil:
            parts.append("passt zum \(remoteLabel)")
        }
        if let result = row.result { parts.append(result.summary) }
        return parts.joined(separator: " · ")
    }
}

private struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(6)
            }
            .frame(height: 160)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: lines.count) { _, count in
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }
}

struct Banner: View {
    enum Kind {
        case info, warning, error

        var color: Color {
            switch self {
            case .info: return .accentColor
            case .warning: return .orange
            case .error: return .red
            }
        }

        var symbol: String {
            switch self {
            case .info: return "info.circle"
            case .warning: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            }
        }
    }

    let text: String
    let kind: Kind

    var body: some View {
        // Als blosser eingefaerbter Text zentrierte `Label` bei mehrzeiligen
        // Meldungen das Symbol senkrecht, was falsch aussieht. Als Flaeche mit
        // Grundlinien-Ausrichtung stimmt beides.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: kind.symbol)
                .font(.caption)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .foregroundStyle(kind.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

