import SwiftUI

/// A scrollable, inline-editable results grid. Double-clicking a cell (when the
/// table is editable) swaps the `Text` for a `TextField`; edits are staged in
/// the `AppModel` and committed by the footer's Save button. New rows appended
/// via `addRow()` are shown below the existing rows with a faint accent tint.
struct EditableResultsGrid: View {
    @ObservedObject var model: AppModel
    let result: QueryResult

    /// Identifies the cell currently being edited. `isNew` distinguishes an
    /// appended (insert) row from an existing (update) row, since the two are
    /// stored separately on the model.
    private struct EditTarget: Equatable {
        var row: Int
        var col: Int
        var isNew: Bool
    }

    private static let columnWidth: CGFloat = 180

    @State private var editing: EditTarget?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        if result.columns.isEmpty {
            ContentUnavailableView("No rows", systemImage: "tablecells")
        } else {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(0..<result.rows.count, id: \.self) { row in
                            dataRow(row, isNew: false)
                        }
                        ForEach(0..<model.newRows.count, id: \.self) { row in
                            dataRow(row, isNew: true)
                        }
                    } header: {
                        headerRow
                    }
                }
            }
            .font(.system(.body, design: .monospaced))
        }
    }

    // MARK: - Rows

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(result.columns.enumerated()), id: \.offset) { item in
                Text(item.element)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: Self.columnWidth, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
        }
        .background(.bar)
    }

    private func dataRow(_ row: Int, isNew: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<result.columns.count, id: \.self) { col in
                cell(row: row, col: col, isNew: isNew)
            }
        }
        .background(isNew ? Color.brandAccent.opacity(0.06) : Color.clear)
    }

    // MARK: - Cell

    @ViewBuilder
    private func cell(row: Int, col: Int, isNew: Bool) -> some View {
        let target = EditTarget(row: row, col: col, isNew: isNew)
        let value = cellValue(row: row, col: col, isNew: isNew)
        let highlighted = isCellHighlighted(row: row, col: col, isNew: isNew)

        Group {
            if editing == target {
                TextField("", text: binding(row: row, col: col, isNew: isNew))
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { endEditing() }
                    .onExitCommand { endEditing() }
            } else {
                cellText(value)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(width: Self.columnWidth, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(highlighted ? Color.brandAccent.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .modifier(EditOnDoubleTap(enabled: model.canEdit) { beginEditing(target) })
    }

    @ViewBuilder
    private func cellText(_ value: String?) -> some View {
        if let value {
            Text(value)
        } else {
            Text("NULL")
                .foregroundStyle(.tertiary)
                .italic()
        }
    }

    // MARK: - Value & binding plumbing

    /// The value shown for a cell. Existing rows reflect any staged edit;
    /// new rows show their staged string (an empty string renders as NULL).
    private func cellValue(row: Int, col: Int, isNew: Bool) -> String? {
        if isNew {
            let raw = model.newRows[row][col]
            return raw.isEmpty ? nil : raw
        } else {
            return model.editedValue(row: row, col: col)
        }
    }

    private func isCellHighlighted(row: Int, col: Int, isNew: Bool) -> Bool {
        if isNew {
            return !model.newRows[row][col].isEmpty
        } else {
            return model.isCellEdited(row: row, col: col)
        }
    }

    private func binding(row: Int, col: Int, isNew: Bool) -> Binding<String> {
        if isNew {
            return Binding(
                get: { model.newRows[row][col] },
                set: { model.setNewRowValue(row, col: col, value: $0) }
            )
        } else {
            return Binding(
                get: { model.editedValue(row: row, col: col) ?? "" },
                set: { model.setEdit(row: row, col: col, value: $0) }
            )
        }
    }

    // MARK: - Editing lifecycle

    private func beginEditing(_ target: EditTarget) {
        editing = target
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func endEditing() {
        editing = nil
        fieldFocused = false
    }
}

/// Attaches a double-click-to-edit gesture only when editing is enabled, so
/// read-only tables keep normal text selection / hit behaviour.
private struct EditOnDoubleTap: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onTapGesture(count: 2, perform: action)
        } else {
            content
        }
    }
}
