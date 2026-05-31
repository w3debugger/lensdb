import Foundation

/// An engine-agnostic view of a SQL server. Both the Postgres and MySQL
/// services conform to this, so the UI and AppModel never branch on engine.
protocol DatabaseService {
    func listDatabases() async throws -> [DatabaseInfo]

    /// Pretty on-disk sizes keyed by database name. Split out of `listDatabases`
    /// because computing them is expensive (Postgres stats every database's
    /// directory; MySQL sums every table) and shouldn't block the list from
    /// appearing — the UI fetches these in the background and merges them in.
    func databaseSizes() async throws -> [String: String]

    func listTables(database: String) async throws -> [TableInfo]
    func runQuery(database: String, sql: String) async throws -> QueryResult

    /// The default "browse everything" statement for a table, with
    /// engine-correct identifier quoting.
    func browseStatement(for table: TableInfo, limit: Int) -> String

    /// Primary-key column names in key order; `[]` when the table has no PK.
    func primaryKeyColumns(database: String, table: TableInfo) async throws -> [String]

    /// Run a write statement (INSERT/UPDATE/…); throws on error.
    func execute(database: String, sql: String) async throws

    /// Build an engine-quoted UPDATE for the given SET assignments and WHERE
    /// match. A nil value becomes `NULL` (or `IS NULL` for a match entry).
    func updateStatement(table: TableInfo, assignments: [(String, String?)], match: [(String, String?)]) -> String

    /// Build an engine-quoted INSERT for the given columns. A nil value
    /// becomes `NULL`.
    func insertStatement(table: TableInfo, columns: [(String, String?)]) -> String
}

enum DBError: LocalizedError {
    case clientNotFound(String)   // includes an install hint
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .clientNotFound(let message): return message
        case .commandFailed(let message): return message
        }
    }
}

extension JSONValue {
    /// Convenience lookup map. Last value wins on duplicate keys, which doesn't
    /// happen for our generated JSON objects.
    var dictionary: [String: JSONValue]? {
        guard let pairs = objectPairs else { return nil }
        return Dictionary(pairs, uniquingKeysWith: { _, last in last })
    }
}

/// Parse one-JSON-object-per-line output (shared by both engines).
func parseJSONObjectLines(_ output: String) -> [JSONValue] {
    output.split(separator: "\n", omittingEmptySubsequences: true)
        .compactMap { JSONParser.parseLine(String($0)) }
}
