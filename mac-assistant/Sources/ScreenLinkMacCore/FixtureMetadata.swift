import Foundation

/// Redacted metadata for an explicit, synthetic notification test. Never logs arbitrary text.
public enum FixtureMetadata {
    public static let marker = "屏间微信通知测试"
    public static func describe(_ text: String, attribute: String) -> [String: String] {
        var result = ["kind": "redacted", "characters": String(text.count)]
        let structuralIDs: Set<String> = ["title", "body", "subtitle", "appName", "notificationTitle", "notificationBody"]
        if attribute == "AXIdentifier", structuralIDs.contains(text) {
            result = ["kind": "structural-identifier", "value": text]
        } else if text == "com.tencent.xinWeChat" {
            result = ["kind": "exact-wechat-bundle", "value": text]
        } else if ["微信", "WeChat", "Weixin"].contains(text) {
            result = ["kind": "exact-wechat-label", "value": text]
        } else if text == marker {
            result = ["kind": "exact-fixture", "value": marker]
        }
        // Only report whether the system card's accessibility description begins
        // with a known app label; never derive source from title/body keywords.
        if attribute == "AXDescription" {
            let delimiters: Set<Character> = [",", "，", "\n"]
            let prefix = String(text.prefix { !delimiters.contains($0) })
            result["exactWeChatDescriptionPrefix"] = String(["微信", "WeChat", "Weixin"].contains(prefix))
        }
        result["containsFixture"] = String(text.contains(marker))
        return result
    }
}
