import SwiftUI

struct DetailView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            QueryBar(model: model)
            Divider()
            // Fill the remaining height so the QueryBar stays pinned to the top.
            // Without this, the empty/error states (a ContentUnavailableView,
            // which only takes its intrinsic height) let the whole VStack shrink
            // and center vertically, leaving a big gap above the SQL bar.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Intentionally no navigationTitle/Subtitle here. The content column
        // owns the toolbar's single title (the selected database name); adding
        // one here too made the two titles overlap when the sidebar collapsed.
        // The selected table is shown in the SQL bar and highlighted in the list.
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.errorMessage, model.result == nil {
            ContentUnavailableView {
                Label("Query failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).font(.system(.body, design: .monospaced))
            }
        } else if let result = model.result {
            EditableResultsGrid(model: model, result: result)
            ResultsFooter(model: model, result: result)
        } else {
            ContentUnavailableView(
                "Browse a table",
                systemImage: "tablecells",
                description: Text("Pick a table on the left, or write SQL above and run it.")
            )
        }
    }
}

// MARK: - SQL bar

struct QueryBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            TextEditor(text: $model.sqlText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(height: 60)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                )

            VStack(spacing: 6) {
                Button {
                    Task { await model.runCurrentQuery() }
                } label: {
                    Label("Run", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(Color.onBrandAccent)
                }
                .buttonStyle(.borderedProminent)
                .tint(.brandAccent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.selectedDatabase == nil || model.isRunningQuery)

                if model.isRunningQuery {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 76)
        }
        .padding(8)
    }
}

// MARK: - Footer

struct ResultsFooter: View {
    @ObservedObject var model: AppModel
    let result: QueryResult

    private var probablyMore: Bool {
        model.selectedTable != nil && result.rowCount >= model.rowLimit
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(result.rowCount) row\(result.rowCount == 1 ? "" : "s")")
                .foregroundStyle(.secondary)

            if probablyMore {
                Button("Load \(AppModel.pageStep) more") {
                    Task { await model.loadMore() }
                }
                .controlSize(.small)
                .disabled(model.isRunningQuery)
            }

            if model.canEdit {
                Button {
                    model.addRow()
                } label: {
                    Text("＋ Add row")
                }
                .controlSize(.small)

                Button {
                    Task { await model.saveChanges() }
                } label: {
                    Text(model.hasPendingChanges
                         ? "Save \(model.pendingChangeCount) change\(model.pendingChangeCount == 1 ? "" : "s")"
                         : "Save")
                }
                .buttonStyle(.borderedProminent)
                .tint(.brandAccent)
                .controlSize(.small)
                .disabled(!model.hasPendingChanges || model.isSaving)

                if let saveError = model.saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else if model.selectedTable != nil, model.primaryKey.isEmpty {
                Text("Read-only · no primary key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let table = model.selectedTable, table.estimatedRows > 0 {
                Text("~\(table.estimatedRows) rows total (estimate)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - Connection settings

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ConnectionSettings()
    @State private var urlText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Connection").font(.title2).bold()

            Picker("Engine", selection: $draft.engine) {
                ForEach(DatabaseEngine.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                if draft.engine == .postgres {
                    TextField("Connection URL", text: $urlText,
                              prompt: Text("postgresql://user:pass@host:5432/db?sslmode=require"))
                }
                TextField("Host", text: $draft.host, prompt: Text("localhost / socket"))
                TextField("Port", text: $draft.port, prompt: Text(draft.engine.defaultPort))
                TextField("User", text: $draft.user, prompt: Text(NSUserName()))
                SecureField("Password", text: $draft.password, prompt: Text("none"))
                TextField("Database", text: $draft.database,
                          prompt: Text(draft.engine == .postgres ? "postgres (default)" : "all"))
                Toggle("Require SSL/TLS", isOn: $draft.requireSSL)
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Connection") {
                    var newValue = draft
                    let trimmedURL = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedURL.isEmpty, let parsed = ConnectionSettings.parsing(url: trimmedURL, into: draft) {
                        newValue = parsed
                    }
                    dismiss()
                    Task { await model.addConnection(newValue) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var hint: String {
        switch draft.engine {
        case .postgres:
            return "Leave everything blank for a local server (Unix socket, current macOS user). For a cloud database, fill in host/user/password and the database name — or just paste a connection URL above."
        case .mysql:
            return "Leave host blank for a local server. For a cloud database, fill in host/user/password. Requires the mysql client (brew install mysql-client)."
        }
    }
}
