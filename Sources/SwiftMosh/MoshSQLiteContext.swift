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
        createSchemaIfNeeded()
        restoreIfPossible()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Overrides for incremental persistence

    public override func reserveOutgoingSequence() -> UInt64 {
        let value = super.reserveOutgoingSequence()
        upsertMeta()
        return value
    }

    public override func reserveInstructionID() -> UInt64 {
        let value = super.reserveInstructionID()
        upsertMeta()
        return value
    }

    public override func advanceExpectedIncomingSequence(to sequence: UInt64) {
        super.advanceExpectedIncomingSequence(to: sequence)
        upsertMeta()
    }

    public override func applyRemoteStateNum(_ stateNum: UInt64) {
        super.applyRemoteStateNum(stateNum)
        insertAppliedState(stateNum)
        pruneAppliedStatesIfNeeded()
    }

    public override func pruneAppliedRemoteStates(before throwawayNum: UInt64) {
        super.pruneAppliedRemoteStates(before: throwawayNum)
        deleteAppliedStates(before: throwawayNum)
    }

    public override func updateLastSentStateNum(_ stateNum: UInt64) {
        super.updateLastSentStateNum(stateNum)
        upsertMeta()
    }

    public override func enqueuePendingOutbound(_ pending: PendingOutboundInstruction) {
        super.enqueuePendingOutbound(pending)
        insertPendingOutbound(pending)
    }

    public override func acknowledgePendingOutbound(through ackNum: UInt64) {
        super.acknowledgePendingOutbound(through: ackNum)
        deletePendingOutbound(through: ackNum)
    }

    public override func recordRetransmit(stateNum: UInt64, nowMs: UInt64, nextRetryAtMs: UInt64) {
        super.recordRetransmit(stateNum: stateNum, nowMs: nowMs, nextRetryAtMs: nextRetryAtMs)
        updatePendingOutboundRetransmit(stateNum: stateNum, nowMs: nowMs, nextRetryAtMs: nextRetryAtMs)
    }

    public override func restore(from snapshot: MoshSessionContextSnapshot) {
        super.restore(from: snapshot)
        syncFullSnapshotToDB(snapshot: snapshot)
    }

    // MARK: - SQLite Schema

    private func openDatabase() {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(dbPath, &db, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = db != nil ? String(cString: sqlite3_errmsg(db)) : "unknown"
            fatalError("Failed to open SQLite database at \(dbPath): \(msg)")
        }
    }

    private func createSchemaIfNeeded() {
        let sql = """
            CREATE TABLE IF NOT EXISTS mosh_session_meta (
                session_id TEXT PRIMARY KEY,
                next_outgoing_sequence INTEGER NOT NULL DEFAULT 0,
                expected_incoming_sequence INTEGER NOT NULL DEFAULT 0,
                next_instruction_id INTEGER NOT NULL DEFAULT 0,
                last_sent_state_num INTEGER NOT NULL DEFAULT 0,
                latest_received_state_num INTEGER NOT NULL DEFAULT 0,
                updated_at_ms INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS mosh_session_applied_states (
                session_id TEXT NOT NULL,
                state_num INTEGER NOT NULL,
                PRIMARY KEY (session_id, state_num)
            );
            CREATE TABLE IF NOT EXISTS mosh_session_pending_outbound (
                session_id TEXT NOT NULL,
                state_num INTEGER NOT NULL,
                instruction_blob BLOB NOT NULL,
                retry_count INTEGER NOT NULL DEFAULT 0,
                last_sent_at_ms INTEGER NOT NULL,
                next_retry_at_ms INTEGER NOT NULL,
                sequence_order INTEGER NOT NULL,
                PRIMARY KEY (session_id, state_num)
            );
            CREATE INDEX IF NOT EXISTS idx_pending_order ON mosh_session_pending_outbound(session_id, sequence_order);
            """
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK, let errMsg {
            let message = String(cString: errMsg)
            sqlite3_free(errMsg)
            fatalError("Failed to create schema: \(message)")
        }
    }

    // MARK: - Incremental Writes

    private func upsertMeta() {
        let now = TransportClock.nowMs()
        let sql = """
            INSERT INTO mosh_session_meta (
                session_id, next_outgoing_sequence, expected_incoming_sequence,
                next_instruction_id, last_sent_state_num, latest_received_state_num, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET
                next_outgoing_sequence = excluded.next_outgoing_sequence,
                expected_incoming_sequence = excluded.expected_incoming_sequence,
                next_instruction_id = excluded.next_instruction_id,
                last_sent_state_num = excluded.last_sent_state_num,
                latest_received_state_num = excluded.latest_received_state_num,
                updated_at_ms = excluded.updated_at_ms;
            """
        let snapshot = makeSnapshot()
        exec(sql) { stmt in
            sqlite3_bind_text(stmt, 1, self.cString(self.sessionID), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(snapshot.nextOutgoingSequence))
            sqlite3_bind_int64(stmt, 3, Int64(snapshot.expectedIncomingSequence))
            sqlite3_bind_int64(stmt, 4, Int64(snapshot.nextInstructionID))
            sqlite3_bind_int64(stmt, 5, Int64(snapshot.lastSentStateNum))
            sqlite3_bind_int64(stmt, 6, Int64(snapshot.latestReceivedStateNum))
            sqlite3_bind_int64(stmt, 7, Int64(now))
        }
    }

    private func insertAppliedState(_ stateNum: UInt64) {
        let sql = "INSERT OR IGNORE INTO mosh_session_applied_states (session_id, state_num) VALUES (?, ?);"
        exec(sql) { stmt in
            sqlite3_bind_text(stmt, 1, self.cString(self.sessionID), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(stateNum))
        }
    }

    private func pruneAppliedStatesIfNeeded() {
        let countSQL = "SELECT COUNT(*) FROM mosh_session_applied_states WHERE session_id = ?;"
        var count: Int64 = 0
        query(countSQL, binder: { stmt in
            sqlite3_bind_text(stmt, 1, self.cString(self.sessionID), -1, SQLITE_TRANSIENT)
        }) { stmt in
            count = sqlite3_column_int64(stmt, 0)
        }
        guard count > 4096 else { return }

        let floor = latestReceivedStateNum > 2048 ? latestReceivedStateNum - 2048 : 0
        deleteAppliedStates(before: floor)
    }

    private func deleteAppliedStates(before throwawayNum: UInt64) {
        let sql = "DELETE FROM mosh_session_applied_states WHERE session_id = ? AND state_num < ?;"
        exec(sql) { stmt in
            sqlite3_bind_text(stmt, 1, self.cString(self.sessionID), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(throwawayNum))
        }
    }

    private func insertPendingOutbound(_ pending: PendingOutboundInstruction) {
        guard let blob = try? encoder.encode(pending.instruction) else { return }
        let order = nextSequenceOrder()
        let sql = """
            INSERT INTO mosh_session_pending_outbound
            (session_id, state_num, instruction_blob, retry_count, last_sent_at_ms, next_retry_at_ms, sequence_order)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id, state_num) DO UPDATE SET
                instruction_blob = excluded.instruction_blob,
                retry_count = excluded.retry_count,
                last_sent_at_ms = excluded.last_sent_at_ms,
                next_retry_at_ms = excluded.next_retry_at_ms,
                sequence_order = excluded.sequence_order;
            """
        exec(sql) { stmt in
            sqlite3_bind_text(stmt, 1, self.cString(self.sessionID), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(pending.stateNum))
            sqlite3_bind_blob(stmt, 3, (blob as NSData).bytes, Int32(blob.count), SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 4, Int64(pending.retryCount))
            sqlite3_bind_int64(stmt, 5, Int64(pending.lastSentAtMs))
            sqlite3_bind_int64(stmt, 6, Int64(pending.nextRetryAtMs))
            sqlite3_bind_int64(stmt, 7, Int64(order))
        }
    }

    private func deletePendingOutbound(through ackNum: UInt64) {
        let sql = "DELETE FROM mosh_session_pending_outbound WHERE session_id = ? AND state_num <= ?;"
        exec(sql) { stmt in
            sqlite3_bind_text(stmt, 1, self.cString(self.sessionID), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(ackNum))
        }
    }

    private func updatePendingOutboundRetransmit(stateNum: UInt64, nowMs: UInt64, nextRetryAtMs: UInt64) {
        let sql = """
            UPDATE mosh_session_pending_outbound
            SET retry_count = retry_count + 1,
                last_sent_at_ms = ?,
                next_retry_at_ms = ?
            WHERE session_id = ? AND state_num = ?;
            """
        exec(sql) { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(nowMs))
            sqlite3_bind_int64(stmt, 2, Int64(nextRetryAtMs))
            sqlite3_bind_text(stmt, 3, self.cString(self.sessionID), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 4, Int64(stateNum))
        }
    }

    private func nextSequenceOrder() -> Int64 {
        let sql = "SELECT COALESCE(MAX(sequence_order), 0) + 1 FROM mosh_session_pending_outbound WHERE session_id = ?;"
        var result: Int64 = 1
        query(sql, binder: { stmt in
            sqlite3_bind_text(stmt, 1, self.cString(self.sessionID), -1, SQLITE_TRANSIENT)
        }) { stmt in
            result = sqlite3_column_int64(stmt, 0)
        }
        return result
    }

    private func syncFullSnapshotToDB(snapshot: MoshSessionContextSnapshot) {
        let now = TransportClock.nowMs()
        let metaSQL = """
            INSERT INTO mosh_session_meta (
                session_id, next_outgoing_sequence, expected_incoming_sequence,
                next_instruction_id, last_sent_state_num, latest_received_state_num, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET
                next_outgoing_sequence = excluded.next_outgoing_sequence,
                expected_incoming_sequence = excluded.expected_incoming_sequence,
                next_instruction_id = excluded.next_instruction_id,
                last_sent_state_num = excluded.last_sent_state_num,
                latest_received_state_num = excluded.latest_received_state_num,
                updated_at_ms = excluded.updated_at_ms;
            """
        exec(metaSQL) { stmt in
            sqlite3_bind_text(stmt, 1, self.cString(self.sessionID), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(snapshot.nextOutgoingSequence))
            sqlite3_bind_int64(stmt, 3, Int64(snapshot.expectedIncomingSequence))
            sqlite3_bind_int64(stmt, 4, Int64(snapshot.nextInstructionID))
            sqlite3_bind_int64(stmt, 5, Int64(snapshot.lastSentStateNum))
            sqlite3_bind_int64(stmt, 6, Int64(snapshot.latestReceivedStateNum))
            sqlite3_bind_int64(stmt, 7, Int64(now))
        }

        let deleteAppliedSQL = "DELETE FROM mosh_session_applied_states WHERE session_id = ?;"
        exec(deleteAppliedSQL) { stmt in
            sqlite3_bind_text(stmt, 1, self.cString(self.sessionID), -1, SQLITE_TRANSIENT)
        }
        for stateNum in snapshot.appliedRemoteStateNums {
            insertAppliedState(stateNum)
        }

        let deletePendingSQL = "DELETE FROM mosh_session_pending_outbound WHERE session_id = ?;"
        exec(deletePendingSQL) { stmt in
            sqlite3_bind_text(stmt, 1, self.cString(self.sessionID), -1, SQLITE_TRANSIENT)
        }
        let pendingByStateNum = Dictionary(uniqueKeysWithValues: snapshot.pendingOutbound.map { ($0.stateNum, $0) })
        for stateNum in snapshot.pendingOutboundOrder {
            if let pending = pendingByStateNum[stateNum] {
                insertPendingOutbound(pending)
            }
        }
    }

    // MARK: - Restore

    private func restoreIfPossible() {
        guard let meta = readMetaRow() else { return }

        var appliedStates: [UInt64] = []
        let appliedSQL = "SELECT state_num FROM mosh_session_applied_states WHERE session_id = ?;"
        query(appliedSQL, binder: { stmt in
            sqlite3_bind_text(stmt, 1, self.cString(self.sessionID), -1, SQLITE_TRANSIENT)
        }) { stmt in
            appliedStates.append(UInt64(sqlite3_column_int64(stmt, 0)))
        }

        var pendingOutbounds: [PendingOutboundInstruction] = []
        var pendingOrder: [UInt64] = []
        let pendingSQL = """
            SELECT state_num, instruction_blob, retry_count, last_sent_at_ms, next_retry_at_ms
            FROM mosh_session_pending_outbound
            WHERE session_id = ?
            ORDER BY sequence_order ASC;
            """
        query(pendingSQL, binder: { stmt in
            sqlite3_bind_text(stmt, 1, self.cString(self.sessionID), -1, SQLITE_TRANSIENT)
        }) { stmt in
            let stateNum = UInt64(sqlite3_column_int64(stmt, 0))
            guard let blob = sqlite3_column_blob(stmt, 1) else { return }
            let length = sqlite3_column_bytes(stmt, 1)
            let data = Data(bytes: blob, count: Int(length))
            guard let instruction = try? self.decoder.decode(TransportInstruction.self, from: data) else { return }
            let retryCount = UInt32(sqlite3_column_int64(stmt, 2))
            let lastSentAtMs = UInt64(sqlite3_column_int64(stmt, 3))
            let nextRetryAtMs = UInt64(sqlite3_column_int64(stmt, 4))
            pendingOutbounds.append(PendingOutboundInstruction(
                stateNum: stateNum,
                instruction: instruction,
                retryCount: retryCount,
                lastSentAtMs: lastSentAtMs,
                nextRetryAtMs: nextRetryAtMs
            ))
            pendingOrder.append(stateNum)
        }

        let snapshot = MoshSessionContextSnapshot(
            nextOutgoingSequence: meta.nextOutgoingSequence,
            expectedIncomingSequence: meta.expectedIncomingSequence,
            nextInstructionID: meta.nextInstructionID,
            lastSentStateNum: meta.lastSentStateNum,
            latestReceivedStateNum: meta.latestReceivedStateNum,
            appliedRemoteStateNums: appliedStates,
            srttMs: nil,
            rttvarMs: nil,
            currentRtoMs: Double(config.initialRtoMs),
            lastSentAtMs: nil,
            lastReceivedAtMs: nil,
            pendingOutbound: pendingOutbounds,
            pendingOutboundOrder: pendingOrder
        )
        restore(from: snapshot)
    }

    private struct MetaRow {
        var nextOutgoingSequence: UInt64
        var expectedIncomingSequence: UInt64
        var nextInstructionID: UInt64
        var lastSentStateNum: UInt64
        var latestReceivedStateNum: UInt64
    }

    private func readMetaRow() -> MetaRow? {
        let sql = """
            SELECT next_outgoing_sequence, expected_incoming_sequence, next_instruction_id,
                   last_sent_state_num, latest_received_state_num
            FROM mosh_session_meta WHERE session_id = ? LIMIT 1;
            """
        var result: MetaRow?
        query(sql, binder: { stmt in
            sqlite3_bind_text(stmt, 1, self.cString(self.sessionID), -1, SQLITE_TRANSIENT)
        }) { stmt in
            result = MetaRow(
                nextOutgoingSequence: UInt64(sqlite3_column_int64(stmt, 0)),
                expectedIncomingSequence: UInt64(sqlite3_column_int64(stmt, 1)),
                nextInstructionID: UInt64(sqlite3_column_int64(stmt, 2)),
                lastSentStateNum: UInt64(sqlite3_column_int64(stmt, 3)),
                latestReceivedStateNum: UInt64(sqlite3_column_int64(stmt, 4))
            )
        }
        return result
    }

    // MARK: - SQLite Helpers

    private func cString(_ str: String) -> UnsafePointer<CChar> {
        return str.cString(using: .utf8)!
    }

    private func exec(_ sql: String, binder: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        binder(stmt!)
        sqlite3_step(stmt)
    }

    private func query(_ sql: String, binder: (OpaquePointer) -> Void, rowHandler: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        binder(stmt!)
        while sqlite3_step(stmt) == SQLITE_ROW {
            rowHandler(stmt!)
        }
    }
}
