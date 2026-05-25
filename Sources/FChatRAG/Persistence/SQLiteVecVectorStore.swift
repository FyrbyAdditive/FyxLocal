import Foundation
import GRDB
import FChatCore

/// `VectorStore` backed by a per-collection sqlite-vec `vec0` virtual table.
///
/// Each collection gets its own table sized to its embedder's dimension at
/// creation time. We talk to it through the shared `RAGDatabase` connection.
public actor SQLiteVecVectorStore: VectorStore {
    public nonisolated let dim: Int
    public nonisolated let distance: DistanceMetric
    /// Quoted table name, e.g. `"vec_3F5E…"`. Built from the collection id
    /// at init time; sqlite-vec table names must be valid SQL identifiers.
    private let tableName: String
    private let database: RAGDatabase

    public init(database: RAGDatabase, collectionID: CollectionID, dim: Int, distance: DistanceMetric) throws {
        self.database = database
        self.dim = dim
        self.distance = distance
        let name = Self.tableName(for: collectionID)
        self.tableName = name
        try database.queue.write { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS \(name)
                USING vec0(chunk_id TEXT PRIMARY KEY, embedding FLOAT[\(dim)])
                """)
        }
    }

    static func tableName(for id: CollectionID) -> String {
        // UUID hex without dashes — guaranteed valid as a SQLite identifier.
        let raw = id.rawValue.uuidString.replacingOccurrences(of: "-", with: "")
        return "vec_\(raw)"
    }

    public func upsert(_ entries: [(ChunkID, [Float])]) throws {
        guard !entries.isEmpty else { return }
        for (_, vector) in entries {
            if vector.count != dim {
                throw VectorStoreError.dimensionMismatch(expected: dim, got: vector.count)
            }
        }
        try database.queue.write { db in
            for (id, vector) in entries {
                let key = id.rawValue.uuidString
                let json = Self.vectorAsJSONArray(vector)
                // sqlite-vec's vec0 doesn't support ON CONFLICT UPDATE for the
                // embedding column directly; delete + insert is the documented
                // upsert pattern.
                try db.execute(sql: "DELETE FROM \(self.tableName) WHERE chunk_id = ?", arguments: [key])
                try db.execute(
                    sql: "INSERT INTO \(self.tableName)(chunk_id, embedding) VALUES (?, vec_f32(?))",
                    arguments: [key, json]
                )
            }
        }
    }

    public func delete(_ ids: [ChunkID]) {
        guard !ids.isEmpty else { return }
        try? database.queue.write { db in
            for id in ids {
                try db.execute(sql: "DELETE FROM \(self.tableName) WHERE chunk_id = ?", arguments: [id.rawValue.uuidString])
            }
        }
    }

    public func search(query: [Float], topK: Int) throws -> [VectorSearchHit] {
        guard query.count == dim else { throw VectorStoreError.dimensionMismatch(expected: dim, got: query.count) }
        guard topK > 0 else { return [] }
        let json = Self.vectorAsJSONArray(query)
        return try database.queue.read { db in
            // sqlite-vec's KNN: WHERE embedding MATCH vec_f32(?) AND k = ?
            // Distance is returned in the `distance` column (L2 by default).
            // For cosine we'd normalise both sides; vec0 doesn't have a
            // built-in cosine distance, but with L2-normalised vectors L2
            // distance is monotonic with cosine, so the ranking matches.
            let rows = try Row.fetchAll(db, sql: """
                SELECT chunk_id, distance
                FROM \(self.tableName)
                WHERE embedding MATCH vec_f32(?) AND k = ?
                ORDER BY distance
                """, arguments: [json, topK])
            return rows.compactMap { row -> VectorSearchHit? in
                guard
                    let key: String = row["chunk_id"],
                    let uuid = UUID(uuidString: key),
                    let dist: Double = row["distance"]
                else { return nil }
                // Convert distance → similarity-ish score for the caller
                // (higher = closer). For L2 we negate; for cosine inputs
                // the value is small for similar items so this still ranks.
                let score = Float(-dist)
                return VectorSearchHit(chunkID: ChunkID(rawValue: uuid), score: score)
            }
        }
    }

    public func count() -> Int {
        (try? database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(self.tableName)") ?? 0
        }) ?? 0
    }

    public func drop() throws {
        try database.queue.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS \(self.tableName)")
        }
    }

    /// sqlite-vec's `vec_f32()` accepts JSON-array text like `"[1.0, 2.0, 3.0]"`.
    static func vectorAsJSONArray(_ vector: [Float]) -> String {
        var s = "["
        for (i, v) in vector.enumerated() {
            if i > 0 { s += "," }
            s += String(v)
        }
        s += "]"
        return s
    }
}
