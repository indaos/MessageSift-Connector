import Foundation
import SQLite3

/// Read-only SQLite access. Opens with SQLITE_OPEN_READONLY; never writes to another app's database.
final class ReadOnlyDatabase {
    private var db: OpaquePointer?

    init?(path: String) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 2000)
    }

    deinit { sqlite3_close(db) }

    /// Rows as [column: value] (Int64, Double, String, Data or nil).
    func query(_ sql: String, _ bindings: [Double] = []) -> [[String: Any?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in bindings.enumerated() { sqlite3_bind_double(stmt, Int32(i + 1), value) }
        var rows: [[String: Any?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any?] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, c)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, c)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, c))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    row[name] = n > 0 ? Data(bytes: sqlite3_column_blob(stmt, c), count: n) : Data()
                default: row[name] = nil
                }
            }
            rows.append(row)
        }
        return rows
    }
}

enum Access: Equatable { case readable, denied, missing }

/// SQLite returns a REAL column as Int64 when the stored value is a whole number.
func number(_ value: Any??) -> Double? {
    switch value {
    case let d as Double: return d
    case let i as Int64: return Double(i)
    default: return nil
    }
}

/// Where the data is, and whether macOS lets this app read it (Full Disk Access).
enum Sources {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var notificationDatabases: [URL] {
        var urls = [home.appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")]
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count) > 0 {
            urls.append(URL(fileURLWithPath: String(cString: buffer)).appendingPathComponent("com.apple.notificationcenter/db2/db"))
        }
        return urls
    }

    static var whatsAppFolder: URL { home.appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared") }
    static var whatsAppStore: URL { whatsAppFolder.appendingPathComponent("ChatStorage.sqlite") }

    /// Opens the file and reads one byte: access(2) can say yes while macOS still blocks the read.
    static func probe(_ url: URL) -> Access {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return errno == ENOENT || errno == ENOTDIR ? .missing : .denied }
        defer { close(fd) }
        var byte: UInt8 = 0
        return read(fd, &byte, 1) >= 0 ? .readable : .denied
    }

    static var notificationDatabase: URL? { notificationDatabases.first { probe($0) == .readable } }

    /// Full Disk Access is on when the Notification Center database (always present) can be read.
    static var hasFullDiskAccess: Bool { notificationDatabase != nil }

    // MARK: Reading

    static func notificationRecords(since: Date) -> [NotificationParser.Record] {
        guard let url = notificationDatabase, let db = ReadOnlyDatabase(path: url.path) else { return [] }
        let rows = db.query("""
            SELECT r.rec_id AS rec_id, r.uuid AS uuid, r.data AS data, r.delivered_date AS delivered, a.identifier AS app
            FROM record r JOIN app a ON a.app_id = r.app_id
            WHERE r.delivered_date > ? ORDER BY r.rec_id DESC LIMIT 5000
            """, [since.timeIntervalSinceReferenceDate])
        return rows.compactMap { row in
            guard let data = row["data"] as? Data, let app = row["app"] as? String else { return nil }
            let id = (row["uuid"] as? Data).map { $0.map { String(format: "%02x", $0) }.joined() } ?? "\(row["rec_id"] as? Int64 ?? 0)"
            return .init(id: id, app: app, data: data, delivered: number(row["delivered"]).map(Date.init(timeIntervalSinceReferenceDate:)))
        }
    }

    /// Chat apps with notifications (bundle ids and counts only), for the share list.
    static func notifyingApps() -> [(app: String, count: Int)] {
        guard let url = notificationDatabase, let db = ReadOnlyDatabase(path: url.path) else { return [] }
        return db.query("SELECT a.identifier AS app, count(r.rec_id) AS n FROM app a JOIN record r ON r.app_id = a.app_id GROUP BY a.identifier")
            .compactMap { row in
                guard let app = row["app"] as? String, !app.hasPrefix("com.apple."), !app.hasPrefix("_"),
                      !NotificationParser.isSlack(app), !NotificationParser.isWhatsApp(app), !app.hasPrefix("com.dmikaya.") else { return nil }
                return (app, Int(row["n"] as? Int64 ?? 0))
            }
            .sorted { $0.count > $1.count }
    }

    static func whatsAppRows(since: Date) -> [WhatsAppParser.Row]? {
        guard probe(whatsAppStore) == .readable, let db = ReadOnlyDatabase(path: whatsAppStore.path) else { return nil }
        return db.query("""
            SELECT m.Z_PK AS id, m.ZTEXT AS text, m.ZMESSAGEDATE AS date, m.ZISFROMME AS me, m.ZMESSAGETYPE AS type,
                   m.ZFROMJID AS fromjid, m.ZPUSHNAME AS push, s.ZCONTACTJID AS chatjid, s.ZPARTNERNAME AS partner,
                   gm.ZCONTACTNAME AS memberName, gm.ZMEMBERJID AS memberjid, i.ZMETADATA AS meta
            FROM ZWAMESSAGE m
            JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
            LEFT JOIN ZWAGROUPMEMBER gm ON gm.Z_PK = m.ZGROUPMEMBER
            LEFT JOIN ZWAMEDIAITEM i ON i.Z_PK = m.ZMEDIAITEM
            WHERE m.ZMESSAGEDATE > ? ORDER BY m.ZMESSAGEDATE DESC LIMIT 10000
            """, [since.timeIntervalSinceReferenceDate]).compactMap(whatsAppRow)
    }

    static func whatsAppRow(_ r: [String: Any?]) -> WhatsAppParser.Row? {
        guard let chat = r["chatjid"] as? String, let date = number(r["date"]) else { return nil }
        return .init(id: r["id"] as? Int64 ?? 0, text: r["text"] as? String, date: date,
                     fromMe: number(r["me"]) == 1, type: Int64(number(r["type"]) ?? 0), fromJID: r["fromjid"] as? String,
                     pushName: r["push"] as? String, chatJID: chat, partner: r["partner"] as? String,
                     memberName: r["memberName"] as? String, memberJID: r["memberjid"] as? String, metadata: r["meta"] as? Data)
    }

    /// Your own phone number and LID digits, from WhatsApp's shared preferences (for group mentions).
    static func whatsAppIdentity() -> [String] {
        let prefs = NSDictionary(contentsOf: whatsAppFolder.appendingPathComponent(
            "Library/Preferences/group.net.whatsapp.WhatsApp.shared.plist")) as? [String: Any] ?? [:]
        return [prefs["OwnPhoneNumber"] as? String, prefs["lid"] as? String].compactMap { $0.flatMap(WhatsAppParser.digits(ofJID:)) }
    }
}
