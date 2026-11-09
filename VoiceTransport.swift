import Foundation

protocol VoiceTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func upload(for request: URLRequest, fromFile file: URL) async throws -> (Data, URLResponse)
}

struct NetworkTransport: VoiceTransport {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { try await session.data(for: request) }
    func upload(for request: URLRequest, fromFile file: URL) async throws -> (Data, URLResponse) { try await session.upload(for: request, fromFile: file) }
}
