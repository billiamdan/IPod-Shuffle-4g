// SPDX-FileCopyrightText: 2026 billiamdan
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The text in an editable field, together with the stored value it was last in step with.
///
/// An editor that fills its fields once and writes them all back when it closes will undo any
/// change made elsewhere in the meantime: rename a playlist in the sidebar, and a details panel
/// that still holds the old name puts it back. A draft avoids that in two ways. It follows the
/// stored value until the user types something different, and it only ever hands back a value
/// the user actually changed.
public struct FieldDraft: Equatable, Sendable {
    /// What the field shows. Bind the text field to this.
    public var text: String
    private var stored: String

    public init(_ value: String) {
        text = value
        stored = value
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// True while the field holds something the user typed that has not been saved.
    public var isEdited: Bool { trimmed != stored }

    /// The stored value changed (here or elsewhere). The field follows it unless the user is mid-edit.
    public mutating func follow(_ value: String) {
        if !isEdited { text = value }
        stored = value
    }

    /// The user's new value, if they changed the field; `nil` when there is nothing to save.
    /// After this the field counts as saved. With `allowEmpty: false` an emptied field is put back
    /// to the stored value instead of being saved.
    public mutating func takeEdit(allowEmpty: Bool = true) -> String? {
        let value = trimmed
        guard value != stored else { return nil }
        guard allowEmpty || !value.isEmpty else {
            text = stored
            return nil
        }
        stored = value
        return value
    }
}
