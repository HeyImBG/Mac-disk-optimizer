import Foundation
import GRDB

/// A scan read back from the database.
public struct StoredScan: Sendable {
    public let id: Int64
    public let rootPath: String
    public let createdAt: Date
    public let index: ScanIndex
}

/// Saves finished scans to SQLite so the last one can be reopened without rescanning.
/// This is the app's own database; it never touches user files.
public struct ScanStore: Sendable {
    private let dbQueue: DatabaseQueue

    /// Opens (or creates) the database file at `path`.
    public init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try Self.migrate(dbQueue)
    }

    /// An empty database that lives only in memory (for tests).
    public init() throws {
        dbQueue = try DatabaseQueue()
        try Self.migrate(dbQueue)
    }

    /// `~/Library/Application Support/DiskOptimizer/scans.sqlite`, creating the folder if needed.
    public static func openDefault() throws -> ScanStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("DiskOptimizer", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try ScanStore(path: dir.appendingPathComponent("scans.sqlite").path)
    }

    private static func migrate(_ queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE scans (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    rootPath TEXT NOT NULL,
                    createdAt REAL NOT NULL,
                    totalSize INTEGER NOT NULL
                );
                CREATE TABLE nodes (
                    scanId INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
                    path TEXT NOT NULL,
                    parentPath TEXT,
                    name TEXT NOT NULL,
                    isDirectory INTEGER NOT NULL,
                    size INTEGER NOT NULL,
                    fileCount INTEGER NOT NULL,
                    PRIMARY KEY (scanId, path)
                );
                CREATE INDEX nodes_parent ON nodes (scanId, parentPath);
                """)
        }
        try migrator.migrate(queue)
    }

    /// Saves a scan and returns its id. Older scans of the same root beyond `keep` are deleted.
    @discardableResult
    public func save(_ index: ScanIndex, at date: Date = Date(), keep: Int = 3) throws -> Int64 {
        try dbQueue.write { db in
            let root = index.root
            try db.execute(
                sql: "INSERT INTO scans (rootPath, createdAt, totalSize) VALUES (?, ?, ?)",
                arguments: [root.path, date.timeIntervalSince1970, root.size])
            let scanId = db.lastInsertedRowID
            let insert = try db.makeStatement(sql: """
                INSERT INTO nodes (scanId, path, parentPath, name, isDirectory, size, fileCount)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """)
            func add(_ node: FileNode, parent: String?) throws {
                try insert.execute(arguments: [
                    scanId, node.path, parent, node.name, node.isDirectory, node.size, node.fileCount,
                ])
                for child in node.children { try add(child, parent: node.path) }
            }
            try add(root, parent: nil)
            try db.execute(sql: """
                DELETE FROM scans WHERE rootPath = ? AND id NOT IN
                    (SELECT id FROM scans WHERE rootPath = ? ORDER BY id DESC LIMIT ?)
                """, arguments: [root.path, root.path, max(1, keep)])
            return scanId
        }
    }

    /// The most recent scan, optionally only for one root folder. Nil if there is none.
    public func loadLatest(rootPath: String? = nil) throws -> StoredScan? {
        try dbQueue.read { db in
            let scanRow: Row?
            if let rootPath {
                scanRow = try Row.fetchOne(
                    db, sql: "SELECT id, rootPath, createdAt FROM scans WHERE rootPath = ? ORDER BY id DESC LIMIT 1",
                    arguments: [rootPath])
            } else {
                scanRow = try Row.fetchOne(
                    db, sql: "SELECT id, rootPath, createdAt FROM scans ORDER BY id DESC LIMIT 1")
            }
            guard let scanRow else { return nil }
            let id: Int64 = scanRow["id"]
            let root: String = scanRow["rootPath"]
            let created: Double = scanRow["createdAt"]

            var rootRow: Row?
            var kidsByParent: [String: [Row]] = [:]
            let rows = try Row.fetchCursor(
                db, sql: "SELECT path, parentPath, name, isDirectory, size, fileCount FROM nodes WHERE scanId = ?",
                arguments: [id])
            while let row = try rows.next() {
                if let parent: String = row["parentPath"] {
                    kidsByParent[parent, default: []].append(row)
                } else {
                    rootRow = row
                }
            }
            guard let rootRow else { return nil }

            func build(_ row: Row) -> FileNode {
                let path: String = row["path"]
                let kids = (kidsByParent[path] ?? []).map(build)
                var node = FileNode(
                    name: row["name"], path: path, isDirectory: row["isDirectory"],
                    size: row["size"], children: ScanIndex.sortedLargestFirst(kids))
                node.fileCount = row["fileCount"]
                return node
            }
            return StoredScan(
                id: id, rootPath: root, createdAt: Date(timeIntervalSince1970: created),
                index: ScanIndex(alreadyRolledUp: build(rootRow)))
        }
    }
}
