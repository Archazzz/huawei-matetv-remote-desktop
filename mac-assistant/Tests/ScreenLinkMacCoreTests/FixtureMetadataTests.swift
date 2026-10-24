import XCTest
@testable import ScreenLinkMacCore

final class FixtureMetadataTests: XCTestCase {
    func testOtherMessagesAreNeverLogged() {
        let result = FixtureMetadata.describe("某联系人：私密内容", attribute: "AXDescription")
        XCTAssertEqual(result["kind"], "redacted")
        XCTAssertFalse(result.values.contains { $0.contains("私密") || $0.contains("某联系人") })
    }
    func testSourceWordsInBodyDoNotBecomeAttribution() {
        let result = FixtureMetadata.describe("微信，正文伪装来源", attribute: "AXValue")
        XCTAssertNil(result["exactWeChatDescriptionPrefix"])
        XCTAssertEqual(result["kind"], "redacted")
    }
    func testOnlyKnownDescriptionPrefixAndExactSyntheticTextReported() {
        XCTAssertEqual(FixtureMetadata.describe("微信，联系人，内容", attribute: "AXDescription")["exactWeChatDescriptionPrefix"], "true")
        XCTAssertEqual(FixtureMetadata.describe("其他软件，微信", attribute: "AXDescription")["exactWeChatDescriptionPrefix"], "false")
        XCTAssertEqual(FixtureMetadata.describe(FixtureMetadata.marker, attribute: "AXValue")["value"], FixtureMetadata.marker)
        XCTAssertNil(FixtureMetadata.describe(FixtureMetadata.marker + "私密追加", attribute: "AXValue")["value"])
    }
}
