/// Selection behavior for a native list whose compact row can expand into an inline editor.
///
/// A selected macOS list row receives the system accent fill. That is useful while navigating
/// compact rows, but it paints an expanded editor as one large blue block. Every inline list editor
/// uses this state so opening the editor clears its row selection and later clicks on controls in
/// that row cannot select it again.
public struct InlineListEditingState<ID: Hashable>: Equatable {
    public private(set) var editingID: ID?

    public init(editingID: ID? = nil) {
        self.editingID = editingID
    }

    /// Opens an editor and returns the empty selection its enclosing list must adopt.
    public mutating func beginEditing(_ id: ID) -> Set<ID> {
        editingID = id
        return []
    }

    /// Filters a selection proposed by the native list while an editor is open.
    ///
    /// Selecting the editing row means a control inside it was clicked, so the selection remains
    /// empty. Selecting a different row closes the editor and preserves normal list navigation.
    public mutating func acceptSelection(_ proposed: Set<ID>) -> Set<ID> {
        guard let editingID else { return proposed }

        let outsideEditor = proposed.subtracting([editingID])
        guard !outsideEditor.isEmpty else { return [] }

        self.editingID = nil
        return outsideEditor
    }

    /// Closes the editor and optionally returns keyboard selection to its compact row.
    public mutating func endEditing(restoringSelection id: ID? = nil) -> Set<ID> {
        editingID = nil
        return id.map { [$0] } ?? []
    }
}
