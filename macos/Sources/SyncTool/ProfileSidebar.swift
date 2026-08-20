import SwiftUI
import SyncCore

/// Die Profilliste mit Anlegen, Duplizieren und Loeschen.
///
/// Der zweite Abschnitt "Programm" ist kein Beiwerk: Schluesselpaar und
/// rsync-Fassung gelten fuer die ganze App, standen bisher aber in
/// profilbezogenen Abschnitten. Wer dort las "Schluessel liegt unter
/// Application Support", musste denken, dieses Profil habe einen eigenen.
struct ProfileSidebar: View {
    @ObservedObject var state: AppState
    @Binding var pendingDeletion: Profile?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                Section("Profile") {
                    ForEach(state.profiles) { profile in
                        row(profile).tag(SettingsSelection.profile(profile.id))
                    }
                    .onMove { indices, destination in
                        state.profiles.move(fromOffsets: indices, toOffset: destination)
                        state.scheduleSave()
                    }
                }
                Section("Programm") {
                    Label("Allgemein", systemImage: "gearshape")
                        .tag(SettingsSelection.general)
                }
            }
            .listStyle(.sidebar)

            Divider()
            footer
        }
    }

    private var selection: Binding<SettingsSelection?> {
        Binding(get: { state.editingSelection }, set: { new in
            guard new != state.editingSelection else { return }
            // Beim Wechsel sofort schreiben: Was im vorigen Profil getippt
            // wurde, darf nicht in der Sammelfrist haengen bleiben.
            state.flushSave()
            state.editingSelection = new
        })
    }

    private func row(_ profile: Profile) -> some View {
        HStack(spacing: 8) {
            marker(profile)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name.isEmpty ? "Ohne Namen" : profile.name)
                    .lineLimit(1)
                Text(profile.isComplete ? profile.summary : "unvollständig")
                    .font(.caption)
                    .foregroundStyle(profile.isComplete ? .secondary : Color.orange)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Duplizieren") { state.duplicateProfile(id: profile.id) }
            Button("Als aktives Ziel wählen") { state.selectProfile(profile.id) }
                .disabled(profile.id == state.selectedProfileID)
            Divider()
            Button("Löschen …", role: .destructive) { pendingDeletion = profile }
        }
    }

    @ViewBuilder
    private func marker(_ profile: Profile) -> some View {
        if !profile.isComplete {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help("Diesem Profil fehlen Angaben")
        } else if profile.id == state.selectedProfileID {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(.tint)
                .help("Dieses Profil ist im Statusfenster gewählt")
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Button { state.addProfile() } label: { Image(systemName: "plus") }
                .help("Profil anlegen")

            Button {
                if let profile = state.editingProfile { pendingDeletion = profile }
            } label: { Image(systemName: "minus") }
                .disabled(state.editingProfile == nil)
                .help("Profil löschen")

            Spacer()

            Menu {
                Button("Duplizieren") {
                    if let id = state.editingSelection?.profileID {
                        state.duplicateProfile(id: id)
                    }
                }
                .disabled(state.editingProfile == nil)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}
