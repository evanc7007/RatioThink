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

  func test_accessibility_text_preserves_full_model_id() {
    XCTAssertEqual(
      ProfileModelPickerLabel.accessibilityText(for: longModelID),
      "Default model: \(longModelID)")
  }
}
