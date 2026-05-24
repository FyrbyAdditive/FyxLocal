import Foundation
import FChatCore

public struct OpenAIResponsesProvider: LLMProvider {
    public let id: ProviderID
    public let baseURL: URL
    public let session: URLSession
    public let secretStore: SecretStore
    public let extraHeaders: [String: String]

    public init(
        id: ProviderID,
        baseURL: URL,
        session: URLSession = .shared,
        secretStore: SecretStore,
        extraHeaders: [String: String] = [:]
    ) {
        self.id = id
        self.baseURL = baseURL
        self.session = session
        self.secretStore = secretStore
        self.extraHeaders = extraHeaders
    }

    public func listModels() async throws -> [ModelInfo] {
        var request = URLRequest(url: baseURL.appending(path: "models"))
        request.httpMethod = "GET"
        try await applyAuth(&request)
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, body: data)
        return try Self.decodeModels(data)
    }

    static func decodeModels(_ data: Data) throws -> [ModelInfo] {
        struct ListResponse: Decodable {
            struct Model: Decodable {
                let id: String
                let owned_by: String?
                // Different servers report the context window under different
                // names. Try the lot in priority order.
                let context_window: Int?
                let max_model_len: Int? // vLLM
                let context_length: Int? // llama.cpp, ollama, some others
                let max_context_length: Int?
                let max_output_tokens: Int?
                let max_tokens: Int?
            }
            let data: [Model]
        }
        let parsed = try JSONDecoder().decode(ListResponse.self, from: data)
        return parsed.data.map { m in
            let serverWindow = m.context_window
                ?? m.max_model_len
                ?? m.context_length
                ?? m.max_context_length
            let resolvedWindow = serverWindow ?? KnownModelCatalog.contextWindow(for: m.id)
            let serverMaxOut = m.max_output_tokens ?? m.max_tokens
            return ModelInfo(
                id: m.id,
                displayName: m.id,
                contextWindow: resolvedWindow,
                maxOutputTokens: serverMaxOut
            )
        }
    }

    public func embed(_ texts: [String], model: String) async throws -> [[Float]] {
        var request = URLRequest(url: baseURL.appending(path: "embeddings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await applyAuth(&request)
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }

        let body: [String: Any] = ["model": model, "input": texts]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, body: data)
        return try Self.decodeEmbeddings(data, expectedCount: texts.count)
    }

    static func decodeEmbeddings(_ data: Data, expectedCount: Int) throws -> [[Float]] {
        struct R: Decodable {
            struct Entry: Decodable {
                let index: Int
                let embedding: [Float]
            }
            let data: [Entry]
        }
        let parsed = try JSONDecoder().decode(R.self, from: data)
        let sorted = parsed.data.sorted { $0.index < $1.index }
        guard sorted.count == expectedCount else {
            throw ProviderError.malformedResponse("embeddings count mismatch: got \(sorted.count) expected \(expectedCount)")
        }
        return sorted.map { $0.embedding }
    }

    public func streamResponse(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runStream(request: request, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStream(
        request: ChatRequest,
        into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        var urlReq = URLRequest(url: baseURL.appending(path: "responses"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        try await applyAuth(&urlReq)
        for (k, v) in extraHeaders { urlReq.setValue(v, forHTTPHeaderField: k) }
        urlReq.httpBody = try OpenAIResponsesRequestEncoder().encode(request, stream: true)

        let (bytes, response) = try await session.bytes(for: urlReq)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines { body += line + "\n" }
            throw ProviderError.httpStatus(http.statusCode, body: body)
        }

        let parser = SSEParser()
        let decoder = OpenAIResponsesEventDecoder()

        var buffer = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            // Flush whenever we have a newline boundary, to avoid string conversion on every byte.
            if byte == UInt8(ascii: "\n") {
                if let chunk = String(data: buffer, encoding: .utf8) {
                    buffer.removeAll(keepingCapacity: true)
                    for sse in parser.feed(chunk) {
                        if sse.data == "[DONE]" {
                            continuation.yield(.completed)
                            return
                        }
                        if let event = try decoder.decode(sse) {
                            continuation.yield(event)
                        }
                    }
                }
            }
        }
        for sse in parser.finish() {
            if let event = try decoder.decode(sse) {
                continuation.yield(event)
            }
        }
        continuation.yield(.completed)
    }

    private func applyAuth(_ request: inout URLRequest) async throws {
        if let key = try await secretStore.secret(for: KeychainAccount.providerAPIKey(id)) {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    static func validate(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: body, encoding: .utf8) ?? "<binary>"
            throw ProviderError.httpStatus(http.statusCode, body: text)
        }
    }
}
