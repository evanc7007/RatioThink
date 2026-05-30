import XCTest
@testable import RatioThinkCore

/// : the profile editor's model picker lists installed GGUF models
/// but must always include the profile's current model — even if that
/// file is not (or no longer) installed — so the picker never silently
/// drops the value the profile actually carries.
final class ProfileModelOptionsTests: XCTestCase {

  func test_current_model_is_included_even_when_not_installed() {
    let options = ProfileModelOptions.merge(installed: ["b.gguf"], current: "a.gguf")
    XCTAssertEqual(options, ["a.gguf", "b.gguf"],
                   "the profile's current model must appear even if not in the installed set")
  }

  func test_no_duplicate_when_current_is_installed() {
    let options = ProfileModelOptions.merge(installed: ["a.gguf", "b.gguf"], current: "a.gguf")
    XCTAssertEqual(options, ["a.gguf", "b.gguf"])
  }

  func test_sorted_and_deduped() {
    let options = ProfileModelOptions.merge(installed: ["c.gguf", "a.gguf", "a.gguf"], current: "b.gguf")
    XCTAssertEqual(options, ["a.gguf", "b.gguf", "c.gguf"])
  }

  func test_empty_current_yields_just_installed() {
    let options = ProfileModelOptions.merge(installed: ["a.gguf"], current: "")
    XCTAssertEqual(options, ["a.gguf"])
  }
}
