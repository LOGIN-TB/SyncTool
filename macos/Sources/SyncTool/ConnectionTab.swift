import SwiftUI
import SyncCore

/// Ziel und Anmeldung.
///
/// Beides zusammen, weil es eine Aufgabe mit einem pruefbaren Ende ist: Alles
/// hier zahlt auf "Verbindung testen" ein, und der sagt, ob es geklappt hat.
///
/// Die Felder kommen aus `TransportFields.descriptors(for:)` und nicht aus einem
/// festen Formular. Welche Felder ein Ziel braucht, steht damit an genau einer
/// Stelle, und `Profile.issues()` liest dieselbe Liste.
struct ConnectionTab: View {
    @ObservedObject var state: AppState
    let profile: Profile
    @Binding var password: String
    @Binding var working: Bool
    @Binding var touched: Set<ProfileField>
    var focused: FocusState<ProfileField?>.Binding

    /// Der Waehler bleibt offen, bis eine Vorlage gesetzt ist, und laesst sich
    /// spaeter ueber "Anderes Ziel …" wieder aufrufen.
    @State private var choosing = false

    private var preset: ProviderPreset? { ProviderCatalog.preset(for: profile) }

    /// Ein frisches Profil, an dem noch nichts steht.
    ///
    /// `transportRaw` taugt dafuer nicht: ein neues Profil steht auf `sshRsync`,
    /// weil das die Vorbelegung von `Profile()` ist. `providerID` ist das
    /// ehrliche Zeichen fuer "noch keine Vorlage gewaehlt", und ein Altprofil
    /// ohne providerID hat immer einen Server, faellt hier also nicht hinein.
    private var isUntouched: Bool {
        profile.providerID.isEmpty && profile.host.isEmpty && profile.share.isEmpty
            && profile.localRoot.isEmpty
    }

    var body: some View {
        if choosing || isUntouched {
            ProviderChooser(
                state: state,
                profile: profile,
                onCancel: isUntouched ? nil : { choosing = false }
            )
            .onChange(of: profile.providerID) { choosing = false }
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            Section { providerRow }
            Section("Ziel") { targetFields }
            if profile.transport.needsCredentials { credentials }
            Section("Prüfen") { probe }
            if case .sshRsync = profile.transport { sshSection }
        }
        .formStyle(.grouped)
    }

    // MARK: - Kopf

    private var providerRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: preset?.icon ?? "questionmark.circle")
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(preset?.name ?? "Unbekannte Art von Ziel")
                    .font(.body.weight(.medium))
                if let hint = preset?.hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button("Anderes Ziel …") { choosing = true }
        }
    }

    // MARK: - Die Felder dieses Ziels

    @ViewBuilder
    private var targetFields: some View {
        ForEach(profile.fields) { descriptor in
            row(descriptor)
            if let help = descriptor.help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if !profile.isRunnable {
            Banner(
                text: "Dieses Profil kommt aus einer neueren Version von SyncTool. Es bleibt "
                    + "unverändert erhalten, lässt sich hier aber nicht ausführen.",
                kind: .warning
            )
        }
    }

    @ViewBuilder
    private func row(_ descriptor: FieldDescriptor) -> some View {
        switch descriptor.kind {
        case .text:
            LabeledContent(descriptor.label) {
                HStack {
                    TextField(
                        "", text: binding(\Profile[text: descriptor.field]),
                        prompt: Text(descriptor.prompt)
                    )
                    .focused(focused, equals: descriptor.field)
                    mark(descriptor)
                }
            }
        case .integer:
            LabeledContent(descriptor.label) {
                HStack {
                    TextField("", value: binding(\.port), format: .number.grouping(.never))
                        .frame(width: 80)
                        .focused(focused, equals: descriptor.field)
                    mark(descriptor)
                    Spacer()
                }
            }
        case .secret:
            SecureField(descriptor.label, text: $password)
        case .folderPicker(let message):
            LabeledContent(descriptor.label) {
                HStack {
                    Text(
                        profile.text(for: descriptor.field).isEmpty
                            ? "—" : Format.displayPath(profile.text(for: descriptor.field))
                    )
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(
                        profile.text(for: descriptor.field).isEmpty
                            ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
                    )
                    mark(descriptor)
                    Spacer()
                    Button("Wählen …") {
                        if let path = FolderPicker.choose(
                            message: message, startingAt: profile.text(for: descriptor.field)
                        ) {
                            binding(\Profile[text: descriptor.field]).wrappedValue = path
                        }
                    }
                }
            }
        }
    }

    private func mark(_ descriptor: FieldDescriptor) -> some View {
        FieldIssueMark(field: descriptor.field, profile: profile, touched: touched)
    }

    // MARK: - Anmeldung

    @ViewBuilder
    private var credentials: some View {
        Section("Anmeldung") {
            if case .sshRsync = profile.transport {
                Picker("Verfahren", selection: binding(\.authMode)) {
                    Text("Passwort").tag(AuthMode.password)
                    Text("SSH-Schlüssel").tag(AuthMode.publicKey)
                }
                .pickerStyle(.segmented)
            }

            if profile.transport.usesRemoteShell && profile.authMode == .publicKey {
                Text("Das Profil meldet sich mit dem Schlüsselpaar an, siehe „Allgemein“.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                SecureField("Passwort", text: $password)
                HStack {
                    Button("Im Schlüsselbund sichern") {
                        state.savePassword(password, for: profile)
                    }
                    Button("Passwort entfernen") {
                        password = ""
                        state.savePassword("", for: profile)
                    }
                    .disabled(password.isEmpty)
                }
            }
        }
    }

    // MARK: - Prüfen

    /// Ein Knopf mit derselben Beschriftung, dahinter je Transportart ein
    /// anderer Ablauf. Was gemessen wurde, steht danach als Satz mit Zahlen da.
    @ViewBuilder
    private var probe: some View {
        HStack {
            Button("Verbindung testen") {
                working = true
                Task {
                    await state.testConnection(profile: profile, password: password)
                    working = false
                }
            }
            .disabled(working || !profile.isRunnable)

            if profile.transport.usesRemoteShell {
                Button(state.hostKeyIsKnown ? "Host-Key erneut prüfen" : "Host-Key prüfen") {
                    working = true
                    Task {
                        await state.fetchHostKeys()
                        working = false
                    }
                }
                .disabled(working || profile.host.isEmpty)
            }

            if working { ProgressView().controlSize(.small) }
        }

        if profile.transport.usesRemoteShell, !state.hostKeyIsKnown, !profile.host.isEmpty {
            Banner(
                text: "Der Host-Key ist noch nicht bestätigt. Ohne ihn verweigert ssh die "
                    + "Verbindung.",
                kind: .warning
            )
        }

        ForEach(preset?.limits ?? [], id: \.self) { limit in
            Label(limit, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Nur bei ssh

    @ViewBuilder
    private var sshSection: some View {
        Section("SSH-Schlüssel") {
            Button("SSH-Schlüssel auf dem Server einrichten") {
                working = true
                Task {
                    await state.setUpKey(profile: profile, password: password)
                    working = false
                }
            }
            .disabled(working || password.isEmpty)
            Text(
                "Erzeugt einmalig ein Schlüsselpaar, legt den öffentlichen Teil auf dem Ziel "
                    + "ab und stellt das Profil auf Schlüssel um. Danach entfällt die "
                    + "Passwortabfrage."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Profile, Value>) -> Binding<Value> {
        SettingsBinding.make(state: state, profile: profile, keyPath: keyPath)
    }
}
