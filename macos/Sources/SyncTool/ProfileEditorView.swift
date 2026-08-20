import SwiftUI
import SyncCore

/// Editor eines Profils: fester Kopf, darunter drei Reiter.
///
/// Der Name steht im Kopf und nicht in einem Reiter, weil er die Identitaet des
/// Profils ist und keine Einstellung an ihm. Sonst wuesste man beim Blick auf
/// "Backup" nicht mehr, wessen Backup man einstellt.
struct ProfileEditorView: View {
    @ObservedObject var state: AppState
    let profile: Profile

    /// Erst angefasste Felder werden gerueffelt. Wer gerade eine Adresse tippt,
    /// soll nicht nach dem ersten Zeichen ein Warnzeichen sehen.
    @State private var touched: Set<ProfileField> = []
    @State private var password = ""
    @State private var working = false
    @FocusState private var focused: ProfileField?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            TabView(selection: $state.editorTab) {
                ConnectionTab(
                    state: state, profile: profile, password: $password,
                    working: $working, touched: $touched, focused: $focused
                )
                .tabItem { Label("Verbindung", systemImage: "network") }
                .tag(EditorTab.verbindung)

                SyncTab(state: state, profile: profile, touched: $touched, focused: $focused)
                    .tabItem { Label("Abgleich", systemImage: "arrow.triangle.2.circlepath") }
                    .tag(EditorTab.abgleich)

                BackupTab(state: state, profile: profile)
                    .tabItem { Label("Backup", systemImage: "archivebox") }
                    .tag(EditorTab.backup)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .onAppear { password = state.password(for: profile) }
        .onChange(of: profile.id) { _, _ in
            touched = []
            password = state.password(for: profile)
        }
        .onChange(of: focused) { previous, _ in
            // Erst beim Verlassen des Feldes gilt es als angefasst.
            if let previous { touched.insert(previous) }
        }
    }

    // MARK: - Kopf

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                TextField("Name", text: binding(\.name), prompt: Text("Name des Ziels"))
                    .textFieldStyle(.plain)
                    .font(.title2)

                if profile.id == state.selectedProfileID {
                    Label("Aktives Ziel", systemImage: "circle.fill")
                        .font(.caption)
                        .labelStyle(.titleAndIcon)
                        .imageScale(.small)
                        .foregroundStyle(.tint)
                } else {
                    Button("Als aktives Ziel wählen") { state.selectProfile(profile.id) }
                        .controlSize(.small)
                }
            }

            Text(profile.summary)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)

            if !profile.isComplete {
                Banner(
                    text: "Es fehlen noch Angaben: "
                        + profile.issues().map(\.field.label).joined(separator: ", "),
                    kind: .warning
                )
            }
            if let notice = state.settingsNotice {
                Banner(text: notice, kind: .info)
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Profile, Value>) -> Binding<Value> {
        SettingsBinding.make(state: state, profile: profile, keyPath: keyPath)
    }
}

/// Bindung auf ein Feld des bearbeiteten Profils.
///
/// Frei stehend, damit alle Reiter dieselbe benutzen, ohne sie viermal zu
/// wiederholen.
enum SettingsBinding {
    static func make<Value>(
        state: AppState, profile: Profile, keyPath: WritableKeyPath<Profile, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                state.profiles.first { $0.id == profile.id }?[keyPath: keyPath]
                    ?? profile[keyPath: keyPath]
            },
            set: { newValue in
                guard var edited = state.profiles.first(where: { $0.id == profile.id })
                else { return }
                edited[keyPath: keyPath] = newValue
                state.editingProfile = edited
            }
        )
    }
}

/// Warnzeichen am Feld, sobald es einmal verlassen wurde.
struct FieldIssueMark: View {
    let field: ProfileField
    let profile: Profile
    let touched: Set<ProfileField>

    var body: some View {
        if touched.contains(field), let issue = profile.issues().first(where: { $0.field == field })
        {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .help(issue.message)
        }
    }
}
