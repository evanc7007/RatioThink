import XCTest
@testable import RatioThinkCore

final class ModelDisplayNameTests: XCTestCase {
  func test_leaf_of_repo_file_slug_is_the_file_name() {
    XCTAssertEqual(
      ModelDisplayName.leaf("Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"),
      "Qwen3-0.6B-Q8_0.gguf")
  }

  func test_bare_name_passes_through() {
    XCTAssertEqual(ModelDisplayName.leaf("model.gguf"), "model.gguf")
  }

  func test_trailing_slash_does_not_yield_empty() {
    XCTAssertEqual(ModelDisplayName.leaf("repo/file.gguf/"), "file.gguf")
  }

  func test_empty_string_passes_through() {
    XCTAssertEqual(ModelDisplayName.leaf(""), "")
  }
}
