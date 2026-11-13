import Foundation

protocol VoiceTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func upload(for request: URLRequest, fromFile file: URL) async throws -> (Data, URLResponse)
    func download(for request: URLRequest) async throws -> (URL, URLResponse)
}

extension VoiceTransport {
    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        let (data, response) = try await data(for: request)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        return (file, response)
    }
}

struct NetworkTransport: VoiceTransport {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { try await session.data(for: request) }
    func upload(for request: URLRequest, fromFile file: URL) async throws -> (Data, URLResponse) { try await session.upload(for: request, fromFile: file) }
    func download(for request: URLRequest) async throws -> (URL, URLResponse) { try await session.download(for: request) }
}
