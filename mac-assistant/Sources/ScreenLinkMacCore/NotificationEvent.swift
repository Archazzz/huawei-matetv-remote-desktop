import Foundation

public enum AllowedSource: String, Codable, CaseIterable {
    case codex = "com.openai.codex"
    case weChat = "com.tencent.xinWeChat"

    public var appName: String {
        switch self {
        case .codex: return "Codex"
        case .weChat: return "微信"
        }
    }
}

// AX metadata does not establish completeness. No "complete" option exists in this prototype.
public enum ContentState: String, Codable { case unknown, truncated }

public struct NotificationEvent: Codable, Equatable {
    public let eventId: String
    public let appId: String
    public let appName: String
    public let title: String
    public let body: String
    public let createdAt: Int64
    public let expiresAt: Int64
    public let contentState: ContentState

    public init(eventId: String = UUID().uuidString, source: AllowedSource,
                title: String, body: String, createdAt: Int64, expiresAt: Int64,
                contentState: ContentState = .unknown) {
        self.eventId = eventId
        self.appId = source.rawValue
        self.appName = source.appName
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.contentState = contentState
    }

    public func validate(now: Int64) throws {
        guard UUID(uuidString: eventId) != nil,
              let source = AllowedSource(rawValue: appId), appName == source.appName,
              !title.isEmpty || !body.isEmpty,
              title.utf8.count <= 2048, body.utf8.count <= 16384,
              createdAt > 0, createdAt <= now + 60_000,
              expiresAt > now, expiresAt > createdAt, expiresAt - createdAt <= 86_400_000 else {
            throw EventError.invalidEvent
        }
    }
}

public enum EventError: Error { case invalidEvent, invalidEndpoint, invalidToken, unexpectedResponse, rejected(Int) }

public enum SourceIdentity {
    // A notification's text never participates in attribution. The caller must supply
    // the AX element's actual process bundle identifier, not a label found in its body.
    public static func allowedAXOwner(bundleIdentifier: String?) -> AllowedSource? {
        guard let bundleIdentifier else { return nil }
        return AllowedSource(rawValue: bundleIdentifier)
    }
}
