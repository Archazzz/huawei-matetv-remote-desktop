import Foundation

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// Transport building block, deliberately not connected to the AX probe. It must
// not be called until a source adapter proves notification identity and freshness.
public final class EventSender {
    private let endpoint: URL
    private let token: String

    public init(serverOrigin: URL, deviceToken: String) throws {
        guard var components = URLComponents(url: serverOrigin, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host != nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { throw EventError.invalidEndpoint }
        guard !deviceToken.isEmpty, deviceToken.count <= 4096,
              !deviceToken.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw EventError.invalidToken
        }
        components.path = "/v1/events"
        guard let endpoint = components.url else { throw EventError.invalidEndpoint }
        self.endpoint = endpoint
        self.token = deviceToken
    }

    public func request(for event: NotificationEvent, now: Int64) throws -> URLRequest {
        try event.validate(now: now)
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(event)
        return request
    }

    public func post(_ event: NotificationEvent) async throws {
        let request = try request(for: event, now: Int64(Date().timeIntervalSince1970 * 1000))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw EventError.unexpectedResponse }
        guard (200..<300).contains(response.statusCode) else { throw EventError.rejected(response.statusCode) }
    }
}
