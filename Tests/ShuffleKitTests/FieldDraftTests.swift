import Testing
@testable import ShuffleKit

@Suite("Editable fields")
struct FieldDraftTests {
    @Test("A value changed elsewhere is followed, and the old one is never written back")
    func staleValueIsNotWrittenBack() {
        // The details panel is created when the playlist is still called "New Playlist" ...
        var field = FieldDraft("New Playlist")
        // ... then the playlist is renamed in the sidebar ...
        field.follow("Evening Mix")
        #expect(field.text == "Evening Mix")
        #expect(!field.isEdited)
        // ... and when the panel goes away there is nothing for it to save.
        #expect(field.takeEdit() == nil)
    }

    @Test("What the user typed is handed back once, trimmed")
    func editIsReturnedOnce() {
        var field = FieldDraft("Old")
        field.text = "  New name "
        #expect(field.isEdited)
        #expect(field.takeEdit() == "New name")
        #expect(field.takeEdit() == nil)
        // The stored value catching up with the edit changes nothing.
        field.follow("New name")
        #expect(field.takeEdit() == nil)
    }

    @Test("Typing in progress is not overwritten when the stored value changes")
    func keepsUnsavedTyping() {
        var field = FieldDraft("Old")
        field.text = "Half typed"
        field.follow("Changed elsewhere")
        #expect(field.text == "Half typed")
        #expect(field.takeEdit() == "Half typed")
    }

    @Test("A field that may not be empty goes back to the stored value when cleared")
    func emptyNotAllowed() {
        var title = FieldDraft("Song")
        title.text = "   "
        #expect(title.takeEdit(allowEmpty: false) == nil)
        #expect(title.text == "Song")

        var wording = FieldDraft("Say this")
        wording.text = ""
        #expect(wording.takeEdit() == "")
    }

    @Test("Whitespace alone does not count as an edit")
    func whitespaceIsNotAnEdit() {
        var field = FieldDraft("Name")
        field.text = "Name  "
        #expect(!field.isEdited)
        #expect(field.takeEdit() == nil)
    }
}
