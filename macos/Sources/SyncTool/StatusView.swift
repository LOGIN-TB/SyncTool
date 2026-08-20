import SwiftUI
import SyncCore

struct StatusView: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

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

    /// Bewusst ohne jeden Hoehenzwang.
    ///
    /// `MenuBarExtra` im Fenster-Stil richtet die Fensterhoehe nach der
    /// Wunschgroesse dieser Ansicht. Jede feste oder auch nur mindestgesetzte
    /// Hoehe im Inneren macht diese Wunschgroesse mehrdeutig; das Fenster
    /// bleibt dann zu klein, der Stapel staucht seine Kinder, und Kopfzeile,
    /// Inhalt und Fusszeile zeichnen uebereinander. Gegen unbegrenztes Wachsen
    /// hilft nicht eine Deckelung hier, sondern eine bei den langen Listen:
    /// siehe `BoundedList`.
    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, inset)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()

            banners

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, inset)
                .padding(.vertical, 12)

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
        .onChange(of: state.selectedProfileID) { _, _ in
            // Beide haengen am Profil: ein fuer A gesetzter Haken darf nach dem
            // Umschalten auf B nicht stehen bleiben, B erlaubt womoeglich gar
            // kein Loeschen.
            deleteOnTransfer = false
            pendingDeletion = nil
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

    @ViewBuilder
    private var banners: some View {
        let warning = state.rsyncWarning
        let notice = state.notice
        let failure: String? = {
            if case .failed(let message) = state.phase { return message }
            return nil
        }()

        if warning != nil || notice != nil || failure != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let warning { Banner(text: warning, kind: .warning) }
                if let notice { Banner(text: notice, kind: .info) }
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
        } else if let backup = state.lastBackup {
            backupResult(backup)
        } else if let status = state.status {
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

            if !status.isInSync {
                VStack(alignment: .leading, spacing: 8) {
                    if !status.conflicts.isEmpty {
                        ConflictSection(conflicts: status.conflicts)
                    }
                    DriftSection(
                        title: "Vom Server holen",
                        systemImage: "arrow.down.circle",
                        items: status.incoming,
                        bytes: status.incomingBytes
                    )
                    DriftSection(
                        title: "Zum Server schicken",
                        systemImage: "arrow.up.circle",
                        items: status.outgoing,
                        bytes: status.outgoingBytes
                    )
                }
            }

            InventoryBalance(report: status.report)

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

    private func symbol(for status: SyncStatus) -> String {
        if !status.conflicts.isEmpty { return "exclamationmark.triangle.fill" }
        return status.isInSync ? "checkmark.circle.fill" : "arrow.left.arrow.right.circle.fill"
    }

    private func color(for status: SyncStatus) -> Color {
        if !status.conflicts.isEmpty { return .orange }
        return status.isInSync ? .green : .accentColor
    }

    private func headline(for status: SyncStatus) -> String {
        if !status.conflicts.isEmpty {
            return Format.count(
                status.conflicts.count, singular: "Konflikt", plural: "Konflikte"
            )
        }
        if status.isInSync { return "Alles auf gleichem Stand" }
        let offen = status.incoming.count + status.outgoing.count
            + status.deletionsOnPull.count + status.deletionsOnPush.count
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
                            + "du lokal gelöscht. Hochladen entfernt sie auch auf dem Server."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if pull > 0 {
                    Text(
                        "\(Format.count(pull, singular: "Datei wurde", plural: "Dateien wurden")) "
                            + "auf dem Server gelöscht. Herunterladen entfernt sie auch hier."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func actions(_ status: SyncStatus) -> some View {
        HStack(spacing: 10) {
            transferButton(
                title: "Herunterladen", symbol: "arrow.down.circle",
                count: status.incoming.count, deletions: planned(status.deletionsOnPull),
                shortcut: .downArrow
            ) { start(.pull, deletions: status.deletionsOnPull) }

            transferButton(
                title: "Hochladen", symbol: "arrow.up.circle",
                count: status.outgoing.count, deletions: planned(status.deletionsOnPush),
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
        let side = pending.direction == .pull ? "hier" : "auf dem Server"
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
            BoundedList(count: pending.items.count, rowHeight: 15) {
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
    let report: InventoryReport
    @State private var expanded = false

    private var differs: Bool {
        report.remoteFiles != report.localFiles
            || report.remoteDirectories != report.localDirectories
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                side("Server", report.remoteFiles, report.remoteDirectories, report.remoteBytes)
                Image(systemName: differs ? "notequal" : "equal")
                    .font(.caption)
                    .foregroundStyle(differs ? Color.orange : Color.secondary.opacity(0.6))
                    .padding(.top, 18)
                side("Lokal", report.localFiles, report.localDirectories, report.localBytes)
            }

            if report.excludedCount > 0 { excluded }
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
                .foregroundStyle(differs ? Color.orange : .primary)
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
        DisclosureGroup(isExpanded: $expanded) {
            BoundedList(count: report.excluded.count, rowHeight: 14) {
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
                BoundedList(count: items.count, rowHeight: 16) {
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
    let conflicts: [ConflictItem]
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    "Diese Dateien wurden auf beiden Seiten verändert. Welche Richtung du "
                        + "zuerst ausführst, gewinnt – die andere Fassung ist danach weg."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                BoundedList(count: conflicts.count, rowHeight: 32) {
                VStack(alignment: .leading, spacing: 6) {
                ForEach(conflicts.prefix(100)) { conflict in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(conflict.path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(
                            "\(conflict.reason.label) · Server \(Format.timestamp(conflict.remoteModified)) "
                                + "(\(Format.bytes(conflict.remoteSize))) · lokal "
                                + "\(Format.timestamp(conflict.localModified)) (\(Format.bytes(conflict.localSize)))"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
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
