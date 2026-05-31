import Foundation

/// Talks to MySQL/MariaDB (local or cloud) via the `mysql` command-line client.
///
/// Fidelity matches the Postgres path: we re-emit each row with `JSON_OBJECT(...)`
/// and read it with `--raw --batch`, so the existing ordered JSON parser handles
/// column order, NULLs, and exact bigints/decimals without loss.
struct MySQLService: DatabaseService {
    var settings: ConnectionSettings

    private static let clientCandidates = [
        "/opt/homebrew/opt/mysql-client/bin/mysql",
        "/opt/homebrew/bin/mysql",
        "/usr/local/opt/mysql-client/bin/mysql",
        "/usr/local/bin/mysql",
        "/opt/homebrew/opt/mysql/bin/mysql",
        "/usr/local/mysql/bin/mysql",
        "/opt/homebrew/opt/mariadb/bin/mariadb",
        "/opt/homebrew/bin/mariadb",
        "/usr/bin/mysql",
    ]

    static func resolveClient() -> String? {
        let fm = FileManager.default
        return clientCandidates.first { fm.isExecutableFile(atPath: $0) }
    }

    func browseStatement(for table: TableInfo, limit: Int) -> String {
        // In MySQL, a "database" is a schema; TableInfo.schema holds the DB name.
        "SELECT * FROM \(backtick(table.schema)).\(backtick(table.name)) LIMIT \(limit)"
    }

    // MARK: - Public queries

    func listDatabases() async throws -> [DatabaseInfo] {
        // Schema names only — fast. Sizes come from `databaseSizes()` separately.
        let sql = """
        SELECT JSON_OBJECT('name', s.schema_name)
        FROM information_schema.schemata s
        WHERE s.schema_name NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys')
        ORDER BY s.schema_name
        """
        let output = try await run(database: nil, sql: sql, includeHeader: false)
        return parseJSONObjectLines(output).compactMap { value in
            guard let dict = value.dictionary, let name = dict["name"]?.displayString else { return nil }
            return DatabaseInfo(name: name, owner: nil, size: nil)
        }
    }

    func databaseSizes() async throws -> [String: String] {
        // One grouped scan instead of a correlated subquery per schema.
        let sql = """
        SELECT JSON_OBJECT(
                 'name', table_schema,
                 'size', CONCAT(ROUND(SUM(data_length + index_length) / 1048576, 1), ' MB'))
        FROM information_schema.tables
        WHERE table_schema NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys')
        GROUP BY table_schema
        """
        let output = try await run(database: nil, sql: sql, includeHeader: false)
        var sizes: [String: String] = [:]
        for value in parseJSONObjectLines(output) {
            guard let dict = value.dictionary,
                  let name = dict["name"]?.displayString,
                  let size = dict["size"]?.displayString else { continue }
            sizes[name] = size
        }
        return sizes
    }

    func listTables(database: String) async throws -> [TableInfo] {
        let sql = """
        SELECT JSON_OBJECT(
                 'schema', table_schema,
                 'name', table_name,
                 'kind', CASE table_type WHEN 'BASE TABLE' THEN 'table'
                                         WHEN 'VIEW' THEN 'view' ELSE LOWER(table_type) END,
                 'est_rows', IFNULL(table_rows, 0))
        FROM information_schema.tables
        WHERE table_schema = \(literal(database))
        ORDER BY table_name
        """
        let output = try await run(database: nil, sql: sql, includeHeader: false)
        return parseJSONObjectLines(output).compactMap { value in
            guard let dict = value.dictionary,
                  let schema = dict["schema"]?.displayString,
                  let name = dict["name"]?.displayString else { return nil }
            let kind = dict["kind"]?.displayString ?? "table"
            let est = Int64(dict["est_rows"]?.displayString ?? "0") ?? 0
            return TableInfo(schema: schema, name: name, kind: kind, estimatedRows: max(est, 0))
        }
    }

    func runQuery(database: String, sql: String) async throws -> QueryResult {
        var inner = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while inner.hasSuffix(";") { inner.removeLast() }
        guard !inner.isEmpty else { return QueryResult(columns: [], rows: []) }

        // 1) Recover ordered column names from a zero-row header.
        let columns = try await fetchColumnNames(database: database, innerSQL: inner)
        guard !columns.isEmpty else { return QueryResult(columns: [], rows: []) }

        // 2) Re-emit each row as JSON so types/NULLs survive intact.
        let pairs = columns.map { "\(literal($0)), \(backtick($0))" }.joined(separator: ", ")
        let jsonSQL = "SELECT JSON_OBJECT(\(pairs)) FROM (\(inner)) AS _q"
        let output = try await run(database: database, sql: jsonSQL, includeHeader: false)

        var rows: [[String?]] = []
        for value in parseJSONObjectLines(output) {
            guard let dict = value.dictionary else { continue }
            rows.append(columns.map { dict[$0]?.displayString })
        }
        return QueryResult(columns: columns, rows: rows)
    }

    // MARK: - Editing

    func primaryKeyColumns(database: String, table: TableInfo) async throws -> [String] {
        // In MySQL, TableInfo.schema is the database name; the PK constraint is named 'PRIMARY'.
        let sql = """
        SELECT column_name
        FROM information_schema.key_column_usage
        WHERE table_schema = \(literal(table.schema))
          AND table_name = \(literal(table.name))
          AND constraint_name = 'PRIMARY'
        ORDER BY ordinal_position
        """
        let output = try await run(database: nil, sql: sql, includeHeader: false)
        return output.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func execute(database: String, sql: String) async throws {
        _ = try await run(database: database, sql: sql, includeHeader: false)
    }

    func updateStatement(table: TableInfo, assignments: [(String, String?)], match: [(String, String?)]) -> String {
        let qualified = "\(backtick(table.schema)).\(backtick(table.name))"
        let setClause = assignments
            .map { "\(backtick($0.0)) = \(valueLiteral($0.1))" }
            .joined(separator: ", ")
        let whereClause = match
            .map { $0.1 == nil ? "\(backtick($0.0)) IS NULL" : "\(backtick($0.0)) = \(valueLiteral($0.1))" }
            .joined(separator: " AND ")
        return "UPDATE \(qualified) SET \(setClause) WHERE \(whereClause)"
    }

    func insertStatement(table: TableInfo, columns: [(String, String?)]) -> String {
        let qualified = "\(backtick(table.schema)).\(backtick(table.name))"
        let cols = columns.map { backtick($0.0) }.joined(separator: ", ")
        let vals = columns.map { valueLiteral($0.1) }.joined(separator: ", ")
        return "INSERT INTO \(qualified) (\(cols)) VALUES (\(vals))"
    }

    // MARK: - Helpers

    private func fetchColumnNames(database: String, innerSQL: String) async throws -> [String] {
        let sql = "SELECT * FROM (\(innerSQL)) AS _q LIMIT 0"
        let output = try await run(database: database, sql: sql, includeHeader: true)
        guard let header = output.split(separator: "\n", omittingEmptySubsequences: true).first else { return [] }
        return header.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    }

    private func run(database: String?, sql: String, includeHeader: Bool) async throws -> String {
        guard let client = MySQLService.resolveClient() else {
            throw DBError.clientNotFound("Couldn't find the mysql client. Install it with `brew install mysql-client`.")
        }
        // --batch escapes tabs/newlines/backslashes so output stays line-safe.
        // For JSON rows we add --raw (no escaping; JSON already escapes them) and
        // --skip-column-names. For the header probe we keep the column-name row.
        var args = ["--batch"]
        if includeHeader {
            args += ["--column-names"]
        } else {
            args += ["--raw", "--skip-column-names"]
        }
        if !settings.host.isEmpty { args += ["-h", settings.host] }
        if !settings.port.isEmpty { args += ["-P", settings.port] }
        if !settings.user.isEmpty { args += ["-u", settings.user] }
        if let database, !database.isEmpty { args += ["-D", database] }
        if settings.requireSSL { args += ["--ssl-mode=REQUIRED"] }
        args += ["--connect-timeout=10", "-e", sql]

        var env: [String: String] = [:]
        if !settings.password.isEmpty { env["MYSQL_PWD"] = settings.password }

        let result = try await Subprocess.run(executable: client, arguments: args, extraEnv: env)
        guard result.status == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DBError.commandFailed(message.isEmpty ? "mysql exited with status \(result.status)." : message)
        }
        return result.stdout
    }

    private func backtick(_ identifier: String) -> String {
        "`" + identifier.replacingOccurrences(of: "`", with: "``") + "`"
    }

    private func literal(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }

    private func valueLiteral(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return literal(value)
    }
}
