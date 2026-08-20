import Foundation

/// Mengenoperationen auf der Profilliste.
///
/// Bewusst getrennt von der App: hier haengt nichts am MainActor und nichts am
/// Dateisystem, deshalb laesst sich jede Regel einzeln pruefen.
public enum ProfileList {
    /// Weicht vorhandenen Namen aus: aus "Storage Box" wird "Storage Box Kopie",
    /// beim zweiten Mal "Storage Box Kopie 2".
    public static func uniqueName(_ base: String, among existing: [String]) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let candidate = trimmed.isEmpty ? "Profil" : trimmed
        guard existing.contains(candidate) else { return candidate }

        let copy = "\(candidate) Kopie"
        guard existing.contains(copy) else { return copy }
        var index = 2
        while existing.contains("\(copy) \(index)") { index += 1 }
        return "\(copy) \(index)"
    }

    /// Setzt das Duplikat direkt hinter das Original, nicht ans Ende.
    ///
    /// Wer dupliziert, will vergleichen. Am Ende einer laengeren Liste stuenden
    /// Original und Kopie weit auseinander.
    public static func inserted(
        duplicateOf id: UUID, into profiles: [Profile]
    ) -> (profiles: [Profile], newID: UUID?) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            return (profiles, nil)
        }
        let name = uniqueName(profiles[index].name, among: profiles.map(\.name))
        let copy = profiles[index].duplicated(named: name)
        var result = profiles
        result.insert(copy, at: index + 1)
        return (result, copy.id)
    }

    /// Restliste und das Profil, das danach gewaehlt sein soll: der Nachfolger,
    /// sonst der Vorgaenger, sonst nichts.
    public static func removing(
        _ id: UUID, from profiles: [Profile]
    ) -> (profiles: [Profile], next: UUID?) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            return (profiles, nil)
        }
        var result = profiles
        result.remove(at: index)
        guard !result.isEmpty else { return (result, nil) }
        return (result, result[min(index, result.count - 1)].id)
    }

    /// Benutzt ein anderes Profil denselben Schluesselbundeintrag?
    ///
    /// Der Eintrag haengt an Server, Port und Benutzer, nicht an der Kennung.
    /// Nach einem Duplizieren ist das der Normalfall, und deshalb darf eine
    /// Loeschung das Passwort nicht mitnehmen.
    public static func sharesCredential(_ profile: Profile, with profiles: [Profile]) -> Bool {
        profiles.contains {
            $0.id != profile.id && $0.host == profile.host && $0.port == profile.port
                && $0.user == profile.user
        }
    }

    /// Trimmt, verwirft Leeres und Doppeltes, behaelt die Reihenfolge.
    ///
    /// Doppelte Muster sind nicht falsch, aber sie machen die Liste unlesbar,
    /// und als Identitaet in einer Ansicht taugen sie dann nicht mehr.
    public static func normalizedExcludes(_ patterns: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for pattern in patterns {
            let value = pattern.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }
}
