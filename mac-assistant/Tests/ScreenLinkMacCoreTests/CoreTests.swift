import XCTest
@testable import ScreenLinkMacCore

final class CoreTests: XCTestCase {
    let now: Int64 = 1_800_000_000_000
    func event(title: String = "测试完成") -> NotificationEvent {
        NotificationEvent(source: .weChat, title: title, body: "收到一条消息", createdAt: now, expiresAt: now + 60_000)
    }
    func testSourceAttributionNeverUsesTextOrNotificationCenterIdentity() {
        XCTAssertNil(SourceIdentity.allowedAXOwner(bundleIdentifier: "com.apple.notificationcenterui"))
        XCTAssertNil(SourceIdentity.allowedAXOwner(bundleIdentifier: "微信 says Codex"))
        XCTAssertNil(SourceIdentity.allowedAXOwner(bundleIdentifier: "com.openai.codex.helper"))
        XCTAssertEqual(SourceIdentity.allowedAXOwner(bundleIdentifier: "com.tencent.xinWeChat"), .weChat)
    }
    func testRequestKeepsOriginalTextAndServerOwnsDeviceMapping() throws {
        let sender = try EventSender(serverOrigin: URL(string: "https://example.invalid")!, deviceToken: "test-only-token")
        let event = self.event(title: "原文\nEnglish …")
        let request = try sender.request(for: event, now: now)
        XCTAssertEqual(request.url?.path, "/v1/events")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-token")
        let data = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(try JSONDecoder().decode(NotificationEvent.self, from: data), event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["deviceId"]); XCTAssertNil(json["hostId"])
        XCTAssertEqual(json["contentState"] as? String, "unknown")
        XCTAssertEqual(json["createdAt"] as? Int64, now)
    }
    func testInsecureEndpointsAndBadTokensAreRejected() {
        for url in ["http://example.invalid", "https://user:pass@example.invalid", "https://example.invalid/path", "https://example.invalid/?x=y"] {
            XCTAssertThrowsError(try EventSender(serverOrigin: URL(string: url)!, deviceToken: "test"))
        }
        for token in ["", "token\r\nInjected: header", "two words"] {
            XCTAssertThrowsError(try EventSender(serverOrigin: URL(string: "https://example.invalid")!, deviceToken: token))
        }
    }
    func testExpiredOrOversizedEventsAreRejectedWithoutSilentTruncation() {
        XCTAssertThrowsError(try event().validate(now: now + 120_000))
        XCTAssertThrowsError(try event(title: String(repeating: "中", count: 1000)).validate(now: now))
    }
}
