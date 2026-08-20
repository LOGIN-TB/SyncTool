import SwiftUI
import SyncCore

/// „Anbieter wählen“ statt eines leeren Formulars.
///
/// Ein frisches Profil zeigte bisher Adresse, Benutzer, Port und Ordner. Das
/// setzt voraus, dass der Nutzer schon weiss, dass sein Ziel per ssh erreichbar
/// ist. Bei einem OneDrive-Ordner ist keines der vier Felder die richtige Frage.
struct ProviderChooser: View {
    @ObservedObject var state: AppState
    let profile: Profile
    /// Beim nachtraeglichen Wechsel steht schon etwas im Formular, dann gehoert
    /// ein Weg zurueck dazu.
    var onCancel: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                ForEach(ProviderGroup.allCases) { group in
                    let presets = state.providerPresets.filter { $0.group == group }
                    if !presets.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(presets) { preset in
                                row(preset)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Was ist das Ziel?")
                .font(.title3.weight(.semibold))
            Text(
                "SyncTool fragt danach nur die Felder ab, die dieses Ziel wirklich braucht."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            if let onCancel {
                Button("Abbrechen", action: onCancel)
                    .padding(.top, 4)
            }
        }
    }

    private func row(_ preset: ProviderPreset) -> some View {
        Button {
            state.apply(preset, to: profile)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: preset.icon)
                    .font(.title3)
                    .frame(width: 26)
                    .foregroundStyle(preset.unavailable == nil ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.name)
                        .font(.body.weight(.medium))
                    Text(preset.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reason = preset.unavailable {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(preset.limits, id: \.self) { limit in
                        Label(limit, systemImage: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(preset.unavailable != nil)
    }
}
