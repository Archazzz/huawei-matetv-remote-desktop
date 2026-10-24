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
        let sender = try EventSender(serverOrigin: URL(string: "https://example.invalid")!, deviceToken: String(repeating: "t", count: 40))
        let event = self.event(title: "原文\nEnglish …")
        let request = try sender.request(for: event, now: now)
        XCTAssertEqual(request.url?.path, "/v1/events")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + String(repeating: "t", count: 40))
        let data = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(try JSONDecoder().decode(NotificationEvent.self, from: data), event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["appId"] as? String, "wechat")
        XCTAssertNil(json["deviceId"]); XCTAssertNil(json["hostId"])
        XCTAssertEqual(json["contentState"] as? String, "unknown")
        XCTAssertEqual(json["createdAt"] as? Int64, now)
    }
    func testInsecureEndpointsAndBadTokensAreRejected() {
        for url in ["http://example.invalid", "https://user:pass@example.invalid", "https://example.invalid/path", "https://example.invalid/?x=y"] {
            XCTAssertThrowsError(try EventSender(serverOrigin: URL(string: url)!, deviceToken: "test"))
        }
        for token in ["", "short", String(repeating: "字", count: 40), "token\r\nInjected: header", "two words"] {
            XCTAssertThrowsError(try EventSender(serverOrigin: URL(string: "https://example.invalid")!, deviceToken: token))
        }
    }
    func testRelayCharacterLimitsUseUnicodeScalarsAndRejectControls() throws {
        let exact = NotificationEvent(source: .weChat, title: String(repeating: "字", count: 256),
            body: String(repeating: "🙂", count: 8000), createdAt: now, expiresAt: now + 60000)
        XCTAssertNoThrow(try exact.validate(now: now))
        let large = NotificationEvent(source: .weChat, title: "标题", body: String(repeating: "🙂", count: 8001),
            createdAt: now, expiresAt: now + 60000)
        XCTAssertThrowsError(try large.validate(now: now))
        XCTAssertThrowsError(try event(title: "正文\r隐藏").validate(now: now))
    }
    func testExpiredOrOversizedEventsAreRejectedWithoutSilentTruncation() {
        XCTAssertThrowsError(try event().validate(now: now + 120_000))
        XCTAssertThrowsError(try event(title: String(repeating: "中", count: 1000)).validate(now: now))
    }
}
