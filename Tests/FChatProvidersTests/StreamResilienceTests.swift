// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatProviders

/// M3: one malformed event in a stream must not kill the whole turn — it's
/// logged + skipped and the surrounding good events still arrive. An entirely
/// undecodable stream surfaces a `.responseError`, not a silent blank.
@Suite("Stream decode resilience", .serialized)
struct StreamResilienceTests {

    @Test func malformedEventIsSkippedAndGoodEventsSurvive() async throws {
        // Three SSE frames; the middle one decodes to a thrown error.
        let body = """
        data: good-1

        data: BOOM

        data: good-2

        data: [DONE]

        """
        let session = StreamStub.session(body: body)
        let stream = streamSSE(
            session: session,
            makeRequest: { URLRequest(url: StreamStub.url) },
            makeDecode: {
                { sse in
                    let d = sse.data
                    if d.isEmpty { return nil }
                    if d == "BOOM" { throw StreamStubError.boom }
                    return .textDelta(itemID: "x", delta: d)
                }
            },
            isDone: { $0.data == "[DONE]" }
        )

        var deltas: [String] = []
        for try await event in stream {
            if case .textDelta(_, let delta) = event { deltas.append(delta) }
        }
        #expect(deltas == ["good-1", "good-2"])   // BOOM skipped, stream survived
    }

    @Test func allUndecodableSurfacesResponseError() async throws {
        let body = "data: BOOM\n\ndata: [DONE]\n\n"
        let session = StreamStub.session(body: body)
        let stream = streamSSE(
            session: session,
            makeRequest: { URLRequest(url: StreamStub.url) },
            makeDecode: { { _ in throw StreamStubError.boom } },
            isDone: { $0.data == "[DONE]" }
        )
        var sawError = false
        for try await event in stream {
            if case .responseError = event { sawError = true }
        }
        #expect(sawError)
    }
}

private enum StreamStubError: Error { case boom }

private final class StreamStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body: String = ""
    static let url = URL(string: "https://stream.stub.test/v1")!

    static func session(body: String) -> URLSession {
        StreamStub.body = body
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url == url }
    override class func canInit(with task: URLSessionTask) -> Bool { task.currentRequest?.url == url }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let resp = HTTPURLResponse(url: Self.url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
