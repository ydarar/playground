import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal read-only SQLite access. Cursor keeps its DB open in WAL mode; read-only
/// connections see committed data per statement without blocking Cursor.
public final class SQLiteReader {
    private var db: OpaquePointer?

    public init?(path: String) {
        // URI form so we can force read-only; the path contains spaces ("Application Support").
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
        if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) != SQLITE_OK {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 2000)
    }

    deinit { sqlite3_close(db) }

    /// Every column comes back as raw bytes (SQLite converts numbers to their text form).
    public func rows(_ sql: String, _ args: [String] = []) -> [[Data?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), arg, -1, SQLITE_TRANSIENT)
        }
        var out: [[Data?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let count = sqlite3_column_count(stmt)
            var row: [Data?] = []
            row.reserveCapacity(Int(count))
            for c in 0..<count {
                if sqlite3_column_type(stmt, c) == SQLITE_NULL {
                    row.append(nil)
                    continue
                }
                let ptr = sqlite3_column_blob(stmt, c)
                let len = Int(sqlite3_column_bytes(stmt, c))
                if let ptr, len > 0 {
                    row.append(Data(bytes: ptr, count: len))
                } else {
                    row.append(Data())
                }
            }
            out.append(row)
        }
        return out
    }

    public func strings(_ sql: String, _ args: [String] = []) -> [[String?]] {
        rows(sql, args).map { $0.map(J.string) }
    }

    public func firstValue(_ sql: String, _ args: [String] = []) -> Data? {
        guard let row = rows(sql, args).first, let first = row.first else { return nil }
        return first
    }
}
