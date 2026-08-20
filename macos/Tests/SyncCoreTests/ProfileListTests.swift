import Foundation
import Testing

@testable import SyncCore

@Suite("Profile duplizieren")
struct ProfileDuplicationTests {
    private func profile(_ name: String, host: String = "box.example.org", user: String = "u1")
        -> Profile
    {
        Profile(name: name, localRoot: "/tmp", host: host, port: 23, user: user, remotePath: "dev")
    }

    @Test("Ein Duplikat bekommt eine neue Kennung")
    func duplicateGetsANewID() {
        let original = profile("Storage Box")
        let copy = original.duplicated(named: "Storage Box Kopie")
        #expect(copy.id != original.id)
    }

    @Test("Ein Duplikat übernimmt alle übrigen Felder unverändert")
    func duplicateKeepsEverythingElse() {
        var original = profile("Storage Box")
        original.excludes = ["node_modules/"]
        original.deleteAllowed = true
        original.maxDelete = 42
        original.useChecksum = true
        original.backupDestination = "/Volumes/Backup"

        let copy = original.duplicated(named: "Kopie")
        #expect(copy.excludes == original.excludes)
        #expect(copy.deleteAllowed == original.deleteAllowed)
        #expect(copy.maxDelete == original.maxDelete)
        #expect(copy.useChecksum == original.useChecksum)
        #expect(copy.backupDestination == original.backupDestination)
        #expect(copy.host == original.host)
        #expect(copy.name == "Kopie")
    }

    @Test("Ein Duplikat heißt „Storage Box Kopie“")
    func duplicateIsNamedKopie() {
        #expect(ProfileList.uniqueName("Storage Box", among: ["Storage Box"]) == "Storage Box Kopie")
    }

    @Test("Zweimal duplizieren ergibt „Storage Box Kopie 2“")
    func secondDuplicateCountsUp() {
        let existing = ["Storage Box", "Storage Box Kopie"]
        #expect(ProfileList.uniqueName("Storage Box", among: existing) == "Storage Box Kopie 2")
    }

    @Test("Ein freier Name bleibt unverändert")
    func freeNameStays() {
        #expect(ProfileList.uniqueName("Notebook", among: ["Storage Box"]) == "Notebook")
        #expect(ProfileList.uniqueName("  ", among: []) == "Profil")
    }

    /// Der Eintrag haengt an Server, Port und Benutzer. Beim Duplizieren ist im
    /// Schluesselbund deshalb nichts zu tun, das Passwort ist schon da.
    @Test("Das Duplikat teilt sich den Schlüsselbundeintrag mit dem Original")
    func duplicateSharesTheCredential() {
        let original = profile("Storage Box")
        let copy = original.duplicated(named: "Kopie")
        #expect(ProfileList.sharesCredential(copy, with: [original, copy]))
    }

    @Test("Das Duplikat steht hinter dem Original, nicht am Ende der Liste")
    func duplicateSitsRightAfterTheOriginal() {
        let list = [profile("A"), profile("B"), profile("C")]
        let (result, newID) = ProfileList.inserted(duplicateOf: list[0].id, into: list)
        #expect(result.count == 4)
        #expect(result[1].id == newID)
        #expect(result[1].name == "A Kopie")
        #expect(result[2].name == "B")
    }

    @Test("Eine unbekannte Kennung ändert nichts")
    func unknownIDChangesNothing() {
        let list = [profile("A")]
        let (result, newID) = ProfileList.inserted(duplicateOf: UUID(), into: list)
        #expect(result.count == 1)
        #expect(newID == nil)
    }
}

@Suite("Profilliste bearbeiten")
struct ProfileListTests {
    private func profile(_ name: String, host: String = "box.example.org", port: Int = 23,
                         user: String = "u1") -> Profile {
        Profile(name: name, localRoot: "/tmp", host: host, port: port, user: user, remotePath: "dev")
    }

    @Test("Löschen des ersten Profils wählt danach das zweite")
    func removingFirstSelectsSecond() {
        let list = [profile("A"), profile("B"), profile("C")]
        let (result, next) = ProfileList.removing(list[0].id, from: list)
        #expect(result.map(\.name) == ["B", "C"])
        #expect(next == result[0].id)
    }

    @Test("Löschen des letzten Profils wählt danach das vorletzte")
    func removingLastSelectsPrevious() {
        let list = [profile("A"), profile("B"), profile("C")]
        let (result, next) = ProfileList.removing(list[2].id, from: list)
        #expect(result.map(\.name) == ["A", "B"])
        #expect(next == result[1].id)
    }

    /// Frueher verhinderte eine versteckte Regel das Loeschen des letzten
    /// Profils. Wer sein erstes, falsch angelegtes loswerden wollte, musste
    /// erst ein zweites anlegen.
    @Test("Löschen des einzigen Profils lässt eine leere Liste und keine Auswahl zurück")
    func removingTheOnlyProfileLeavesNothing() {
        let list = [profile("A")]
        let (result, next) = ProfileList.removing(list[0].id, from: list)
        #expect(result.isEmpty)
        #expect(next == nil)
    }

    @Test("Eine unbekannte Kennung lässt die Liste unverändert")
    func removingUnknownChangesNothing() {
        let list = [profile("A"), profile("B")]
        let (result, next) = ProfileList.removing(UUID(), from: list)
        #expect(result.count == 2)
        #expect(next == nil)
    }

    @Test("Zwei Profile auf denselben Server teilen sich einen Schlüsselbundeintrag")
    func sameTargetSharesCredential() {
        let a = profile("A")
        let b = profile("B")
        #expect(ProfileList.sharesCredential(a, with: [a, b]))
    }

    @Test("Ein anderer Port bedeutet einen eigenen Schlüsselbundeintrag")
    func differentPortIsItsOwnCredential() {
        let a = profile("A", port: 23)
        let b = profile("B", port: 22)
        #expect(!ProfileList.sharesCredential(a, with: [a, b]))

        let c = profile("C", user: "anders")
        #expect(!ProfileList.sharesCredential(a, with: [a, c]))
    }

    @Test("Ein Profil allein teilt sich nichts")
    func aloneSharesNothing() {
        let a = profile("A")
        #expect(!ProfileList.sharesCredential(a, with: [a]))
    }

    // MARK: - Ausschlüsse

    @Test("Ein Muster wird nicht zweimal in die Ausschlussliste aufgenommen")
    func duplicatePatternsAreDropped() {
        #expect(
            ProfileList.normalizedExcludes(["node_modules/", "*.log", "node_modules/"])
                == ["node_modules/", "*.log"]
        )
    }

    @Test("Leerzeichen um ein Muster werden abgeschnitten")
    func patternsAreTrimmed() {
        #expect(ProfileList.normalizedExcludes(["  .DS_Store  ", "", "   "]) == [".DS_Store"])
    }

    @Test("Die Reihenfolge der Ausschlüsse bleibt beim Entdoppeln erhalten")
    func orderSurvivesDeduplication() {
        let input = ["c", "a", "b", "a", "c"]
        #expect(ProfileList.normalizedExcludes(input) == ["c", "a", "b"])
    }
}
