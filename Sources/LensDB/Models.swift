import Foundation

enum DatabaseEngine: String, CaseIterable, Identifiable, Equatable {
    case postgres = "PostgreSQL"
    case mysql = "MySQL"

    var id: String { rawValue }
    var defaultPort: String { self == .postgres ? "5432" : "3306" }
}

struct ConnectionSettings: Equatable {
    var engine: DatabaseEngine = .postgres
    var host: String = ""        // empty -> local socket
    var port: String = ""        // empty -> engine default
    var user: String = ""        // empty -> current macOS user
    var password: String = ""    // empty -> none / trust / peer
    var database: String = ""    // explicit default DB (required by many cloud providers)
    var requireSSL: Bool = false // force TLS (cloud); otherwise the client negotiates

    var summary: String {
        let host = host.isEmpty ? "local socket" : host
        let port = port.isEmpty ? "" : ":\(port)"
        let user = user.isEmpty ? NSUserName() : user
        let db = database.isEmpty ? "" : "/\(database)"
        return "\(engine.rawValue) · \(user)@\(host)\(port)\(db)"
    }
}

extension ConnectionSettings {
    /// Build settings from a `postgres://`, `postgresql://`, or `mysql://` URL,
    /// keeping unrelated fields from `base`. Returns nil if it can't be parsed.
    static func parsing(url string: String, into base: ConnectionSettings) -> ConnectionSettings? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased() else { return nil }

        var result = base
        switch scheme {
        case "postgres", "postgresql": result.engine = .postgres
        case "mysql", "mariadb": result.engine = .mysql
        default: return nil
        }
        if let host = comps.host, !host.isEmpty { result.host = host }
        if let port = comps.port { result.port = String(port) }
        if let user = comps.user, !user.isEmpty { result.user = user }
        if let password = comps.password { result.password = password }
        if comps.path.count > 1 { result.database = String(comps.path.dropFirst()) }
        if let ssl = comps.queryItems?.first(where: { $0.name.lowercased() == "sslmode" })?.value?.lowercased() {
            result.requireSSL = !["disable", "allow", "prefer"].contains(ssl)
        }
        return result
    }
}

struct DatabaseInfo: Identifiable, Hashable {
    var name: String
    var owner: String?
    var size: String?
    var id: String { name }
}

/// A single saved server connection plus whatever databases we've loaded from
/// it. Multiple connections coexist in the sidebar, each keeping its own list.
struct Connection: Identifiable {
    let id = UUID()
    var settings: ConnectionSettings
    var databases: [DatabaseInfo] = []
    var isLoading = false
    var errorMessage: String?

    /// Short label for the section header.
    var label: String {
        settings.host.isEmpty ? "Local · \(settings.engine.rawValue)" : settings.host
    }
}

/// Identifies one database within one connection. Database names aren't unique
/// across connections, so selection has to carry both.
struct DatabaseSelection: Hashable {
    var connectionID: Connection.ID
    var databaseName: String
}

struct TableInfo: Identifiable, Hashable {
    var schema: String
    var name: String
    var kind: String          // table | view | matview | foreign
    var estimatedRows: Int64
    var id: String { "\(schema).\(name)" }
    var qualifiedName: String { "\(schema).\(name)" }
}

struct QueryResult {
    var columns: [String]
    var rows: [[String?]]     // each row aligned to `columns`; nil == SQL NULL
    var rowCount: Int { rows.count }
}
