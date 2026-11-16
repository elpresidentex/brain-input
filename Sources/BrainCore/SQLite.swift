import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let description: String
}

/// Minimal thread-safe wrapper over the system SQLite (which ships FTS5).
public final class SQLiteDB: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw SQLiteError(description: "cannot open \(path)") }
        sqlite3_busy_timeout(db, 3000)
        try exec("PRAGMA journal_mode=WAL")
    }

    deinit { sqlite3_close(db) }

    public func exec(_ sql: String, _ params: [Any?] = []) throws { _ = try query(sql, params) }

    @discardableResult
    public func query(_ sql: String, _ params: [Any?] = []) throws -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw err(sql) }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() {
            let n = Int32(i + 1)
            switch p {
            case let s as String: sqlite3_bind_text(stmt, n, s, -1, Self.transient)
            case let v as Int: sqlite3_bind_int64(stmt, n, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, n, v)
            default: sqlite3_bind_null(stmt, n)
            }
        }
        var rows: [[String: Any]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw err(sql) }
            var row: [String: Any] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, c)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, c))
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func err(_ sql: String) -> SQLiteError {
        SQLiteError(description: "\(String(cString: sqlite3_errmsg(db))) in: \(sql)")
    }
}
