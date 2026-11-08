import Foundation
import SQLite3

public enum SQLValue: Equatable {
    case int(Int64)
    case double(Double)
    case text(String)
    case null

    public static func opt(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
    public static func opt(_ i: Int?) -> SQLValue { i.map { .int(Int64($0)) } ?? .null }
    public static func opt(_ d: Double?) -> SQLValue { d.map { .double($0) } ?? .null }
    public static func opt(_ b: Bool?) -> SQLValue { b.map { .int($0 ? 1 : 0) } ?? .null }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteDB {
    let handle: OpaquePointer

    public init(path: String) throws {
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let h { sqlite3_close(h) }
            throw SQLiteError(code: rc, message: msg)
        }
        handle = h
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit { sqlite3_close(handle) }

    var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg)
        }
    }

    public func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw SQLiteError(code: rc, message: errorMessage) }
        return Statement(db: self, stmt: stmt)
    }

    public func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let s = try prepare(sql)
        try s.run(values)
    }

    public func query(_ sql: String, _ values: [SQLValue] = []) throws -> [Row] {
        try prepare(sql).query(values)
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    public var changes: Int { Int(sqlite3_changes(handle)) }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

public struct Row {
    public let values: [String: SQLValue]

    public func string(_ k: String) -> String? { if case .text(let s) = values[k] { return s }; return nil }
    public func int(_ k: String) -> Int? {
        switch values[k] {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        default: return nil
        }
    }
    public func int64(_ k: String) -> Int64? {
        switch values[k] {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        default: return nil
        }
    }
    public func double(_ k: String) -> Double? {
        switch values[k] {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    public func bool(_ k: String) -> Bool? { int(k).map { $0 != 0 } }
}

public final class Statement {
    let db: SQLiteDB
    let stmt: OpaquePointer

    init(db: SQLiteDB, stmt: OpaquePointer) { self.db = db; self.stmt = stmt }
    deinit { sqlite3_finalize(stmt) }

    func bind(_ values: [SQLValue]) throws {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch v {
            case .int(let n): rc = sqlite3_bind_int64(stmt, idx, n)
            case .double(let d): rc = sqlite3_bind_double(stmt, idx, d)
            case .text(let s): rc = sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .null: rc = sqlite3_bind_null(stmt, idx)
            }
            if rc != SQLITE_OK { throw SQLiteError(code: rc, message: db.errorMessage) }
        }
    }

    public func run(_ values: [SQLValue] = []) throws {
        try bind(values)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW { throw SQLiteError(code: rc, message: db.errorMessage) }
        sqlite3_reset(stmt)
    }

    public func query(_ values: [SQLValue] = []) throws -> [Row] {
        try bind(values)
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(code: rc, message: db.errorMessage) }
            var dict: [String: SQLValue] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: dict[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: dict[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: dict[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                default: dict[name] = .null
                }
            }
            rows.append(Row(values: dict))
        }
        sqlite3_reset(stmt)
        return rows
    }
}
