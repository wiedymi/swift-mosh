import Foundation
import SQLite3

public final class MoshSQLiteSessionContext: MoshSessionContext {
    private let sessionID: String
    private let dbPath: String
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(sessionID: String, config: MoshClientConfig, dbPath: String) {
        self.sessionID = sessionID
        self.dbPath = dbPath
        super.init(config: config)
        openDatabase()
        createTableIfNeeded()
        restoreIfPossible()
    }

    deinit {
        sqlite3_close(db)
    }

    public override func didMutate() {
        persistSnapshot()
    }

    // MARK: - SQLite

    private func openDatabase() {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(dbPath, &db, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = db != nil ? String(cString: sqlite3_errmsg(db)) : "unknown"
            fatalError("Failed to open SQLite database at \(dbPath): \(msg)")
        }
    }

    private func createTableIfNeeded() {
        let sql = """
            CREATE TABLE IF NOT EXISTS mosh_session_context (
                session_id TEXT PRIMARY KEY,
                snapshot_json BLOB NOT NULL,
                updated_at_ms INTEGER NOT NULL
            );
            """
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK, let errMsg {
            let message = String(cString: errMsg)
            sqlite3_free(errMsg)
            fatalError("Failed to create table: \(message)")
        }
    }

    private func persistSnapshot() {
        let snapshot = makeSnapshot()
        guard let data = try? encoder.encode(snapshot) else { return }
        let now = TransportClock.nowMs()

        let sql = "INSERT OR REPLACE INTO mosh_session_context (session_id, snapshot_json, updated_at_ms) VALUES (?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let cSessionID = sessionID.cString(using: .utf8)
        sqlite3_bind_text(stmt, 1, cSessionID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_blob(stmt, 2, (data as NSData).bytes, Int32(data.count), SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, Int64(now))

        sqlite3_step(stmt)
    }

    private func restoreIfPossible() {
        let sql = "SELECT snapshot_json FROM mosh_session_context WHERE session_id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let cSessionID = sessionID.cString(using: .utf8)
        sqlite3_bind_text(stmt, 1, cSessionID, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return }
        guard let blob = sqlite3_column_blob(stmt, 0) else { return }
        let length = sqlite3_column_bytes(stmt, 0)
        let data = Data(bytes: blob, count: Int(length))

        guard let snapshot = try? decoder.decode(MoshSessionContextSnapshot.self, from: data) else { return }
        restore(from: snapshot)
    }
}
