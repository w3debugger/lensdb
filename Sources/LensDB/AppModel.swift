import SwiftUI
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var connections: [Connection] = []
    @Published var selection: DatabaseSelection?

    /// Connections the user has collapsed in the sidebar. Absence == expanded,
    /// so new connections start expanded and we never have to seed this. It's
    /// kept separate from `connections` on purpose: reloading a connection's
    /// databases (refresh) doesn't touch it, so the collapse state survives.
    @Published var collapsedConnections: Set<Connection.ID> = []

    @Published var tables: [TableInfo] = []
    @Published var selectedTableID: TableInfo.ID?
    @Published var tableSearch = ""

    @Published var sqlText = ""
    @Published var result: QueryResult?
    @Published var rowLimit = defaultRowLimit

    @Published var isLoadingTables = false
    @Published var isRunningQuery = false
    @Published var errorMessage: String?

    // Inline editing state (see "Inline editing" MARK below).
    @Published var pendingEdits: [Int: [Int: String]] = [:]   // existing-row index -> (col index -> new string value)
    @Published var newRows: [[String]] = []                   // appended rows; each is per-column strings, "" = unset
    @Published var primaryKey: [String] = []
    @Published var isSaving = false
    @Published var saveError: String?

    static let defaultRowLimit = 200
    static let pageStep = 200

    private func service(for connection: Connection) -> DatabaseService {
        switch connection.settings.engine {
        case .postgres: return PostgresService(settings: connection.settings)
        case .mysql: return MySQLService(settings: connection.settings)
        }
    }

    var selectedConnection: Connection? {
        guard let id = selection?.connectionID else { return nil }
        return connections.first { $0.id == id }
    }

    var selectedDatabase: DatabaseInfo? {
        guard let selection, let connection = selectedConnection else { return nil }
        return connection.databases.first { $0.name == selection.databaseName }
    }

    var selectedTable: TableInfo? { tables.first { $0.id == selectedTableID } }

    var filteredTables: [TableInfo] {
        guard !tableSearch.isEmpty else { return tables }
        let query = tableSearch.lowercased()
        return tables.filter {
            $0.name.lowercased().contains(query) || $0.schema.lowercased().contains(query)
        }
    }

    /// Schemas in first-seen order, for grouped display.
    var schemaOrder: [String] {
        var order: [String] = []
        for table in filteredTables where !order.contains(table.schema) {
            order.append(table.schema)
        }
        return order
    }

    func tables(in schema: String) -> [TableInfo] {
        filteredTables.filter { $0.schema == schema }
    }

    // MARK: - Connections

    /// Seed the default local connection on first launch and load every
    /// connection's databases, then select the first database we find.
    func bootstrap() async {
        if connections.isEmpty {
            connections = [Connection(settings: ConnectionSettings())]
        }
        for connection in connections {
            await loadDatabases(for: connection.id)
        }
        if selection == nil, let connection = connections.first(where: { !$0.databases.isEmpty }) {
            await selectDatabase(DatabaseSelection(connectionID: connection.id,
                                                   databaseName: connection.databases[0].name))
        }
    }

    /// Append a new connection, load it, and jump to its first database.
    func addConnection(_ settings: ConnectionSettings) async {
        let connection = Connection(settings: settings)
        connections.append(connection)
        await loadDatabases(for: connection.id)
        if let loaded = connections.first(where: { $0.id == connection.id }), let first = loaded.databases.first {
            await selectDatabase(DatabaseSelection(connectionID: connection.id, databaseName: first.name))
        }
    }

    func removeConnection(_ id: Connection.ID) async {
        connections.removeAll { $0.id == id }
        collapsedConnections.remove(id)
        if selection?.connectionID == id {
            await selectDatabase(nil)
        }
    }

    // MARK: - Sidebar collapse state

    func isExpanded(_ id: Connection.ID) -> Bool {
        !collapsedConnections.contains(id)
    }

    func setExpanded(_ id: Connection.ID, _ expanded: Bool) {
        if expanded { collapsedConnections.remove(id) }
        else { collapsedConnections.insert(id) }
    }

    func refreshAll() async {
        for connection in connections {
            await loadDatabases(for: connection.id)
        }
    }

    /// (Re)load the database list for one connection without touching the
    /// others. The array is re-indexed after each await because connections may
    /// be added or removed while this runs.
    func loadDatabases(for id: Connection.ID) async {
        guard let start = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[start].isLoading = true
        connections[start].errorMessage = nil
        let service = service(for: connections[start])
        do {
            let loaded = try await service.listDatabases()
            if let i = connections.firstIndex(where: { $0.id == id }) {
                connections[i].databases = loaded
                connections[i].errorMessage = nil
                connections[i].isLoading = false
            }
            // Sizes are expensive on huge servers, so fetch them off the
            // critical path and merge into the already-visible list.
            Task { await loadSizes(for: id) }
        } catch {
            if let i = connections.firstIndex(where: { $0.id == id }) {
                connections[i].databases = []
                connections[i].errorMessage = error.localizedDescription
                connections[i].isLoading = false
            }
        }
    }

    /// Best-effort: fill in on-disk sizes after the database list is showing.
    /// Failures are silent — sizes are decorative.
    private func loadSizes(for id: Connection.ID) async {
        guard let connection = connections.first(where: { $0.id == id }) else { return }
        guard let sizes = try? await service(for: connection).databaseSizes() else { return }
        guard let i = connections.firstIndex(where: { $0.id == id }) else { return }
        var databases = connections[i].databases
        for k in databases.indices {
            databases[k].size = sizes[databases[k].name]
        }
        connections[i].databases = databases
    }

    // MARK: - Selection & queries

    func selectDatabase(_ selection: DatabaseSelection?) async {
        self.selection = selection
        tables = []
        selectedTableID = nil
        result = nil
        sqlText = ""
        errorMessage = nil
        guard selection != nil else { return }
        await loadTables()
    }

    func loadTables() async {
        guard let connection = selectedConnection, let database = selectedDatabase?.name else { return }
        isLoadingTables = true
        errorMessage = nil
        defer { isLoadingTables = false }
        do {
            tables = try await service(for: connection).listTables(database: database)
        } catch {
            tables = []
            errorMessage = error.localizedDescription
        }
    }

    func selectTable(_ id: TableInfo.ID?) async {
        clearEdits()
        primaryKey = []
        selectedTableID = id
        guard let connection = selectedConnection, let table = selectedTable else { return }
        rowLimit = Self.defaultRowLimit
        sqlText = service(for: connection).browseStatement(for: table, limit: rowLimit)
        await runCurrentQuery()
        primaryKey = (try? await service(for: connection).primaryKeyColumns(database: selectedDatabase?.name ?? "",
                                                                            table: table)) ?? []
    }

    func runCurrentQuery() async {
        clearEdits()   // re-running drops stale edits (but keeps primaryKey)
        guard let connection = selectedConnection, let database = selectedDatabase?.name else { return }
        let sql = sqlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return }
        isRunningQuery = true
        errorMessage = nil
        defer { isRunningQuery = false }
        do {
            result = try await service(for: connection).runQuery(database: database, sql: sql)
        } catch {
            result = nil
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let connection = selectedConnection, let table = selectedTable else { return }
        rowLimit += Self.pageStep
        sqlText = service(for: connection).browseStatement(for: table, limit: rowLimit)
        await runCurrentQuery()
    }

    // MARK: - Inline editing

    /// Editing is only possible when we have a single table backing the result
    /// and a primary key whose columns are all present in the result set.
    var canEdit: Bool {
        selectedTable != nil
            && !primaryKey.isEmpty
            && result != nil
            && primaryKey.allSatisfy { result!.columns.contains($0) }
    }

    /// Edited existing cells plus new rows that carry at least one value.
    var pendingChangeCount: Int {
        let edited = pendingEdits.values.reduce(0) { $0 + $1.count }
        let added = newRows.filter { row in row.contains { !$0.isEmpty } }.count
        return edited + added
    }

    var hasPendingChanges: Bool { pendingChangeCount > 0 }

    func clearEdits() {
        pendingEdits = [:]
        newRows = []
        saveError = nil
    }

    func editedValue(row: Int, col: Int) -> String? {
        pendingEdits[row]?[col] ?? result?.rows[row][col]
    }

    func isCellEdited(row: Int, col: Int) -> Bool {
        pendingEdits[row]?[col] != nil
    }

    /// Store an edit, or remove it (pruning an emptied row dict) when the value
    /// matches the original cell again.
    func setEdit(row: Int, col: Int, value: String) {
        let original = result?.rows[row][col] ?? ""
        if value == original {
            pendingEdits[row]?[col] = nil
            if pendingEdits[row]?.isEmpty == true { pendingEdits[row] = nil }
        } else {
            pendingEdits[row, default: [:]][col] = value
        }
    }

    func addRow() {
        newRows.append(Array(repeating: "", count: result?.columns.count ?? 0))
    }

    func setNewRowValue(_ rowIdx: Int, col: Int, value: String) {
        guard newRows.indices.contains(rowIdx), newRows[rowIdx].indices.contains(col) else { return }
        newRows[rowIdx][col] = value
    }

    func saveChanges() async {
        guard canEdit,
              let connection = selectedConnection,
              let database = selectedDatabase?.name,
              let table = selectedTable,
              let result else { return }
        let service = service(for: connection)

        var statements: [String] = []

        // Updates for edited existing rows.
        for (rowIndex, cols) in pendingEdits {
            let assignments = cols.map { (result.columns[$0.key], Optional($0.value)) }
            let pkIndices = primaryKey.compactMap { result.columns.firstIndex(of: $0) }
            let match = zip(primaryKey, pkIndices).map { (name, pkIndex) in
                (name, result.rows[rowIndex][pkIndex])
            }
            statements.append(service.updateStatement(table: table, assignments: assignments, match: match))
        }

        // Inserts for new rows that carry at least one value.
        for newRow in newRows {
            let filled = newRow.enumerated()
                .filter { !$0.element.isEmpty }
                .map { (result.columns[$0.offset], Optional($0.element)) }
            if filled.isEmpty { continue }
            statements.append(service.insertStatement(table: table, columns: filled))
        }

        isSaving = true
        defer { isSaving = false }
        do {
            for s in statements {
                try await service.execute(database: database, sql: s)
            }
            clearEdits()
            await runCurrentQuery()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
