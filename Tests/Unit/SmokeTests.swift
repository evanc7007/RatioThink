import XCTest
@testable import RatioThink

final class SmokeTests: XCTestCase {
  func test_true() {
    XCTAssertTrue(true)
  }

  func test_pie_dirs_returns_paths_under_application_support() throws {
    let support = try PieDirs.applicationSupport()
    XCTAssertTrue(support.path.contains("Application Support/RatioThink"))
    XCTAssertTrue(try PieDirs.profiles().path.hasSuffix("/profiles"))
    XCTAssertTrue(try PieDirs.models().path.hasSuffix("/models"))
  }
}
