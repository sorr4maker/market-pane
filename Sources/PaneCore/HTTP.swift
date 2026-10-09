import Foundation

public protocol HTTPFetching: Sendable {
    func data(from url: URL, headers: [String: String]) async throws -> Data
}

public extension HTTPFetching {
    func data(from url: URL) async throws -> Data { try await data(from: url, headers: [:]) }
}

public struct URLSessionFetcher: HTTPFetching {
    public init() {}
    public func data(from url: URL, headers: [String: String]) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent") // Yahoo 没有 UA 会拒绝
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

public enum ParseError: Error, Equatable {
    case malformed(String)
    case empty
}

public enum QuoteSource: String, Codable, Sendable { case yahoo, sina, ecb }
