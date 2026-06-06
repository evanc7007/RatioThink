import AppKit
import SwiftUI
import XCTest
@testable import RatioThink

@MainActor
final class ProfileModelPickerLabelTests: XCTestCase {
  private let longModelID =
    "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"

  func test_long_model_id_label_has_bounded_ideal_width() {
    let host = NSHostingView(rootView: ProfileModelPickerLabel(modelID: longModelID))

    XCTAssertLessThanOrEqual(
      host.fittingSize.width,
      ProfileModelPickerLabel.maxLayoutWidth + 1,
      "The profile model picker label must not ask its Settings row to grow for long HF ids")
  }

  func test_accessibility_label_uses_visible_leaf_and_value_preserves_full_model_id() {
    let host = NSHostingView(rootView: ProfileModelPickerLabel(modelID: longModelID))
    host.frame = NSRect(x: 0, y: 0,
                        width: ProfileModelPickerLabel.maxLayoutWidth,
                        height: 32)
    host.layoutSubtreeIfNeeded()
    let accessibilityDump = accessibilityDescriptions(in: host)

    XCTAssertTrue(
      accessibilityDump.contains("label=Default model: \(ModelDisplayName.leaf(longModelID))"),
      "The selected picker label should present the same friendly leaf that is visible in the UI; dump=\(accessibilityDump)")
    XCTAssertTrue(
      accessibilityDump.contains("help=\(longModelID)"),
      "The full resolver slug should remain available through accessibility help even when the visible label is shortened; dump=\(accessibilityDump)")
  }

  private func accessibilityDescriptions(in element: Any) -> [String] {
    guard let object = element as? NSObject else { return [] }
    let label = accessibilityString(object, "accessibilityLabel").map { "label=\($0)" }
    let value = accessibilityString(object, "accessibilityValue").map { "value=\($0)" }
    let help = accessibilityString(object, "accessibilityHelp").map { "help=\($0)" }
    let current = [label, value, help].compactMap(\.self)
    let children = accessibilityChildren(object)
      .flatMap { accessibilityDescriptions(in: $0) }
    return current + children
  }

  private func accessibilityString(_ object: NSObject, _ selector: String) -> String? {
    let selector = NSSelectorFromString(selector)
    guard object.responds(to: selector) else { return nil }
    return object.perform(selector)?.takeUnretainedValue() as? String
  }

  private func accessibilityChildren(_ object: NSObject) -> [Any] {
    let selector = NSSelectorFromString("accessibilityChildren")
    guard object.responds(to: selector) else { return [] }
    return object.perform(selector)?.takeUnretainedValue() as? [Any] ?? []
  }
}
