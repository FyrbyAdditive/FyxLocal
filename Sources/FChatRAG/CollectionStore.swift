import Foundation
import CryptoKit
import FChatCore

public actor CollectionStore {
    public private(set) var collections: [CollectionID: RAGCollection] = [:]
    public private(set) var documents: [DocumentID: RAGDocument] = [:]
    public private(set) var chunks: [ChunkID: RAGChunk] = [:]
    public private(set) var chunkContents: [ChunkID: String] = [:]
    public private(set) var collectionToDocuments: [CollectionID: [DocumentID]] = [:]
    public private(set) var documentToChunks: [DocumentID: [ChunkID]] = [:]
    public private(set) var vectorStores: [CollectionID: any VectorStore] = [:]
    public private(set) var embedders: [CollectionID: any Embedder] = [:]

    public init() {}

    public func createCollection(
        name: String,
        embedder: any Embedder,
        summary: String? = nil,
        distance: DistanceMetric = .cosine
    ) async -> RAGCollection {
        let collection = RAGCollection(
            name: name,
            summary: summary,
            embedder: embedder.kind,
            embeddingModel: embedder.modelID,
            dim: embedder.dim,
            distance: distance
        )
        collections[collection.id] = collection
        embedders[collection.id] = embedder
        vectorStores[collection.id] = InMemoryVectorStore(dim: embedder.dim, distance: distance)
        collectionToDocuments[collection.id] = []
        return collection
    }

    public func collection(named name: String) -> RAGCollection? {
        collections.values.first(where: { $0.name == name })
    }

    public func ingest(
        data: Data,
        filename: String,
        collectionID: CollectionID,
        ingestor: FileIngestor = FileIngestor(),
        chunker: Chunker = Chunker()
    ) async throws -> RAGDocument {
        guard let collection = collections[collectionID] else {
            throw IngestError.unknownCollection
        }
        guard let embedder = embedders[collectionID] else {
            throw IngestError.unknownCollection
        }
        guard let store = vectorStores[collectionID] else {
            throw IngestError.unknownCollection
        }

        let parsed = try ingestor.parse(data: data, filename: filename)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let document = RAGDocument(
            collectionID: collectionID,
            filename: filename,
            kind: parsed.kind,
            sourcePath: nil,
            contentHash: hash,
            byteSize: data.count
        )

        var assembledChunks: [RAGChunk] = []
        var assembledContents: [String] = []
        var ordinal = 0
        for section in parsed.sections {
            let pieces = chunker.chunk(section.text)
            for piece in pieces {
                let chunk = RAGChunk(
                    documentID: document.id,
                    ordinal: ordinal,
                    text: piece,
                    meta: ChunkMeta(page: section.page, section: section.title)
                )
                assembledChunks.append(chunk)
                assembledContents.append(piece)
                ordinal += 1
            }
        }

        guard !assembledChunks.isEmpty else {
            documents[document.id] = document
            collectionToDocuments[collectionID, default: []].append(document.id)
            documentToChunks[document.id] = []
            return document
        }

        let vectors = try await embedder.embed(assembledContents)
        precondition(vectors.count == assembledChunks.count)
        try await store.upsert(zip(assembledChunks, vectors).map { ($0.0.id, $0.1) })

        documents[document.id] = document
        collectionToDocuments[collectionID, default: []].append(document.id)
        documentToChunks[document.id] = assembledChunks.map(\.id)
        for chunk in assembledChunks {
            chunks[chunk.id] = chunk
            chunkContents[chunk.id] = chunk.text
        }
        var updatedCollection = collection
        updatedCollection.updatedAt = .now
        collections[collectionID] = updatedCollection
        return document
    }

    public func search(query: String, in collectionID: CollectionID, topK: Int) async throws -> [VectorSearchHit] {
        guard let embedder = embedders[collectionID], let store = vectorStores[collectionID] else {
            throw IngestError.unknownCollection
        }
        let vector = try await embedder.embed([query])
        return try await store.search(query: vector[0], topK: topK)
    }

    public func chunk(_ id: ChunkID) -> RAGChunk? { chunks[id] }
    public func document(_ id: DocumentID) -> RAGDocument? { documents[id] }
}

public enum IngestError: Error, Sendable, Equatable {
    case unknownCollection
}
