import Foundation

/// Talks to PostgreSQL (local or cloud) by shelling out to `psql`. No driver to
/// link, and results come back as JSON (`row_to_json`) so values stay
/// type/precision-correct.
struct PostgresService: DatabaseService {
    var settings: ConnectionSettings

    private static let psqlCandidates = [
        "/opt/homebrew/bin/psql",
        "/usr/local/bin/psql",
        "/usr/bin/psql",
        "/Applications/Postgres.app/Contents/Versions/latest/bin/psql",
        "/Library/PostgreSQL/16/bin/psql",
        "/Library/PostgreSQL/15/bin/psql",
        "/Library/PostgreSQL/14/bin/psql",
    ]

    static func resolvePsql() -> String? {
        let fm = FileManager.default
        return psqlCandidates.first { fm.isExecutableFile(atPath: $0) }
    }

    func browseStatement(for table: TableInfo, limit: Int) -> String {
        "SELECT * FROM \(quote(table.schema)).\(quote(table.name)) LIMIT \(limit)"
    }

    // MARK: - Public queries

    func listDatabases() async throws -> [DatabaseInfo] {
        // Names + owners only — a fast catalog read. Sizes are fetched
        // separately by `databaseSizes()` so a huge cluster lists instantly.
        let sql = """
        SELECT row_to_json(t) FROM (
          SELECT d.datname AS name,
                 pg_catalog.pg_get_userbyid(d.datdba) AS owner
          FROM pg_catalog.pg_database d
          WHERE d.datistemplate = false
          ORDER BY d.datname
        ) t
        """
        let output = try await runOnAnyMaintenanceDB(sql: sql)
        return parseJSONObjectLines(output).compactMap { value in
            guard let dict = value.dictionary, let name = dict["name"]?.displayString else { return nil }
            return DatabaseInfo(name: name, owner: dict["owner"]?.displayString, size: nil)
        }
    }

    func databaseSizes() async throws -> [String: String] {
        let sql = """
        SELECT row_to_json(t) FROM (
          SELECT d.datname AS name,
                 pg_size_pretty(pg_database_size(d.datname)) AS size
          FROM pg_catalog.pg_database d
          WHERE d.datistemplate = false
            AND has_database_privilege(d.datname, 'CONNECT')
        ) t
        """
        let output = try await runOnAnyMaintenanceDB(sql: sql)
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
        SELECT row_to_json(t) FROM (
          SELECT n.nspname AS schema, c.relname AS name,
                 CASE c.relkind
                   WHEN 'r' THEN 'table' WHEN 'p' THEN 'table'
                   WHEN 'v' THEN 'view'  WHEN 'm' THEN 'matview'
                   WHEN 'f' THEN 'foreign' ELSE c.relkind::text END AS kind,
                 c.reltuples::bigint AS est_rows
          FROM pg_catalog.pg_class c
          JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
          WHERE c.relkind IN ('r','p','v','m','f')
            AND n.nspname NOT IN ('pg_catalog','information_schema')
            AND n.nspname NOT LIKE 'pg_toast%'
            AND n.nspname NOT LIKE 'pg_temp%'
          ORDER BY n.nspname, c.relname
        ) t
        """
        let output = try await runSQL(database: database, sql: sql)
        return parseJSONObjectLines(output).compactMap { value in
            guard let dict = value.dictionary,
                  let schema = dict["schema"]?.displayString,
                  let name = dict["name"]?.displayString else { return nil }
            let kind = dict["kind"]?.displayString ?? "table"
            let est = Int64(dict["est_rows"]?.displayString ?? "0") ?? 0
            return TableInfo(schema: schema, name: name, kind: kind, estimatedRows: max(est, 0))
        }
    }

    /// Runs an arbitrary SELECT and returns it as an ordered column/row grid.
    func runQuery(database: String, sql: String) async throws -> QueryResult {
        var inner = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while inner.hasSuffix(";") { inner.removeLast() }
        guard !inner.isEmpty else { return QueryResult(columns: [], rows: []) }

        let wrapped = "SELECT row_to_json(t) FROM (\(inner)) t"
        let output = try await runSQL(database: database, sql: wrapped)
        let values = parseJSONObjectLines(output)

        var columns: [String] = []
        var seen = Set<String>()
        for value in values {
            guard let pairs = value.objectPairs else { continue }
            for (key, _) in pairs where seen.insert(key).inserted {
                columns.append(key)
            }
        }

        var rows: [[String?]] = []
        rows.reserveCapacity(values.count)
        for value in values {
            guard let dict = value.dictionary else { continue }
            rows.append(columns.map { dict[$0]?.displayString })
        }

        // Empty result still deserves headers if we can recover them.
        if columns.isEmpty {
            columns = (try? await fetchColumnNames(database: database, innerSQL: inner)) ?? []
        }
        return QueryResult(columns: columns, rows: rows)
    }

    // MARK: - Editing

    func primaryKeyColumns(database: String, table: TableInfo) async throws -> [String] {
        let regclass = literal("\(quote(table.schema)).\(quote(table.name))") + "::regclass"
        let sql = """
        SELECT a.attname
        FROM pg_index i
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE i.indrelid = \(regclass) AND i.indisprimary
        ORDER BY array_position(i.indkey, a.attnum)
        """
        let output = try await runSQL(database: database, sql: sql)
        return output.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func execute(database: String, sql: String) async throws {
        _ = try await runSQL(database: database, sql: sql)
    }

    func updateStatement(table: TableInfo, assignments: [(String, String?)], match: [(String, String?)]) -> String {
        let sets = assignments.map { "\(quote($0.0)) = \(literal($0.1))" }.joined(separator: ", ")
        let wheres = match.map { col, value in
            value == nil ? "\(quote(col)) IS NULL" : "\(quote(col)) = \(literal(value))"
        }.joined(separator: " AND ")
        return "UPDATE \(quote(table.schema)).\(quote(table.name)) SET \(sets) WHERE \(wheres)"
    }

    func insertStatement(table: TableInfo, columns: [(String, String?)]) -> String {
        let cols = columns.map { quote($0.0) }.joined(separator: ", ")
        let vals = columns.map { literal($0.1) }.joined(separator: ", ")
        return "INSERT INTO \(quote(table.schema)).\(quote(table.name)) (\(cols)) VALUES (\(vals))"
    }

    // MARK: - Helpers

    private func fetchColumnNames(database: String, innerSQL: String) async throws -> [String] {
        let sql = "SELECT * FROM (\(innerSQL)) q LIMIT 0"
        let output = try await runSQL(database: database, sql: sql, tuplesOnly: false)
        guard let header = output.split(separator: "\n", omittingEmptySubsequences: true).first else { return [] }
        return header.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    }

    /// Tries the explicit database first (cloud), then the usual local
    /// maintenance databases.
    private func runOnAnyMaintenanceDB(sql: String) async throws -> String {
        let fallbackUser = settings.user.isEmpty ? NSUserName() : settings.user
        let candidates = [settings.database, "postgres", fallbackUser, "template1"]
        var lastError: Error?
        var tried = Set<String>()
        for db in candidates where !db.isEmpty && tried.insert(db).inserted {
            do { return try await runSQL(database: db, sql: sql) }
            catch { lastError = error }
        }
        throw lastError ?? DBError.commandFailed("Could not connect to any database.")
    }

    private func connectionArgs(database: String?) -> [String] {
        var args: [String] = []
        if !settings.host.isEmpty { args += ["-h", settings.host] }
        if !settings.port.isEmpty { args += ["-p", settings.port] }
        if !settings.user.isEmpty { args += ["-U", settings.user] }
        if let database { args += ["-d", database] }
        return args
    }

    private func runSQL(database: String?, sql: String, tuplesOnly: Bool = true) async throws -> String {
        guard let psql = PostgresService.resolvePsql() else {
            throw DBError.clientNotFound("Couldn't find the psql executable. Install PostgreSQL (e.g. `brew install postgresql`).")
        }
        var args = ["-X", "-q", "-A", "-w", "-v", "ON_ERROR_STOP=1"]
        if tuplesOnly { args.append("-t") }
        args += connectionArgs(database: database)
        args += ["-c", sql]

        var env: [String: String] = ["PGCONNECT_TIMEOUT": "10"]
        if !settings.password.isEmpty { env["PGPASSWORD"] = settings.password }
        // sslmode only makes sense for TCP connections, not the local socket.
        if settings.requireSSL && !settings.host.isEmpty { env["PGSSLMODE"] = "require" }

        let result = try await Subprocess.run(executable: psql, arguments: args, extraEnv: env)
        guard result.status == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DBError.commandFailed(message.isEmpty ? "psql exited with status \(result.status)." : message)
        }
        return result.stdout
    }

    private func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func literal(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
