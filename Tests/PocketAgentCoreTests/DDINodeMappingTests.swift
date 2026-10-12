import Foundation
import Testing
@testable import PocketAgentCore

struct DDINodeMappingTests {
    private func node(_ attributes: [String: Any]) -> [String: Any] {
        ["21": ["x": 12.5, "y": 84.0, "width": 100.0, "height": 40.0],
         "27": 1, "32": true, "identity": "42:18446744073709551615"].merging(attributes) { _, new in new }
    }
    @Test func distinguishesAXRolesFromXCTestEnums() throws {
        let search = try #require(try DDINodeMapping.attributes(node(["45": 15, "51": 1, "42": "Search", "53": "hello"])))
        #expect(search["type"] == "XCUIElementTypeSearchField")
        #expect(search["label"] == nil) // Placeholder is not an observed label.
        #expect(search["placeholder"] == "Search")
        #expect(search["value"] == "hello")
        #expect(search["ddi_identity"] == "42:18446744073709551615")
        #expect(try DDINodeMapping.attributes(node(["45": 3, "51": 3]))?["type"] == "XCUIElementTypeSwitch")
        #expect(try DDINodeMapping.attributes(node(["45": 123]))?["type"] == "XCUIElementTypeOther")
    }
    @Test func retainsDisabledStateAndDescriptionProvenance() throws {
        let result = try #require(try DDINodeMapping.attributes(node(["45": 2, "27": 0, "33": "Button description"])))
        #expect(result["enabled"] == "false")
        #expect(result["label"] == "Button description")
        #expect(result["ddi_text_source"] == "description")
        let absent = try #require(try DDINodeMapping.attributes(node(["45": 2]).filter { $0.key != "27" }))
        #expect(absent["enabled"] == nil)
    }
    @Test func rejectsInvisibleUnavailableAndNonfiniteFrames() throws {
        #expect(try DDINodeMapping.attributes(node(["32": false])) == nil)
        #expect(try DDINodeMapping.attributes(["21": ["unavailable": "CGRectNull"]]) == nil)
        #expect(try DDINodeMapping.attributes(["21": ["x": Double.nan, "y": 0, "width": 1, "height": 1]]) == nil)
        #expect(try DDINodeMapping.attributes(node(["45": 1])) == nil)
    }
    @Test func secureTextSubroleNeverExportsItsValue() throws {
        let secure = try #require(try DDINodeMapping.attributes(node(["45": 15, "51": 5, "53": "private value"])))
        #expect(secure["type"] == "XCUIElementTypeSecureTextField")
        #expect(secure["value"] == nil)
    }
    @Test func focusedEditableTextViewOmissionDoesNotAssertEmpty() throws {
        let raw = node(["45": 17, "77": (1 << 18) | (1 << 47), "28": true, "3": ""])
        let empty = try #require(try DDINodeMapping.attributes(raw))
        #expect(empty["type"] == "XCUIElementTypeTextView")
        #expect(empty["value"] == nil)
        #expect(empty["ddi_textview_value_omitted"] == "true")
        #expect(!DDINodeMapping.confirmsInput(empty, text: ""))
        #expect(!DDINodeMapping.confirmsInput(empty, text: "new text"))
        for change in [["53": NSNull()], ["53": ["unavailable": true]], ["28": false], ["27": false], ["33": "remaining text"]] as [[String: Any]] {
            #expect(try DDINodeMapping.attributes(raw.merging(change) { _, n in n })?["ddi_textview_value_omitted"] == nil)
        }
        #expect(try DDINodeMapping.attributes(raw.filter { $0.key != "3" })?["ddi_textview_value_omitted"] == "true")
    }
    @Test func missingValueAndPlaceholderNeverConfirmEmptyInput() {
        #expect(!DDINodeMapping.confirmsInput([:], text: ""))
        #expect(!DDINodeMapping.confirmsInput(["placeholder": "Search"], text: ""))
        #expect(DDINodeMapping.confirmsInput(["value": "Search", "placeholder": "Search"], text: ""))
        #expect(DDINodeMapping.confirmsInput(["value": "你好🌟"], text: "你好🌟"))
    }
}
