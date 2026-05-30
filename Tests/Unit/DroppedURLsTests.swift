import XCTest
@testable import RatioThink

/// Unit tests for `DroppedURLs.resolve`. The naive
/// `var url: URL?` pattern that this helper replaces (review v2 F2)
/// dropped every URL past the first and discarded `loadObject`
/// errors. These assertions pin the multi-URL contract.
final class DroppedURLsTests: XCTestCase {

  func test_resolve_collects_every_dropped_url() {
    let urls = [
      URL(fileURLWithPath: "/tmp/one.gguf"),
      URL(fileURLWithPath: "/tmp/two.gguf"),
      URL(fileURLWithPath: "/tmp/three.gguf"),
    ]
    let providers = urls.map { NSItemProvider(object: $0 as NSURL) }
    let expectation = expectation(description: "completion fires once")
    DroppedURLs.resolve(providers) { res in
      XCTAssertEqual(Set(res.urls), Set(urls),
                     "every dropped URL must reach the caller — naive `var url: URL?` would have kept only one")
      XCTAssertEqual(res.errors, [])
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 2)
  }

  func test_resolve_invokes_completion_with_empty_arrays_for_no_providers() {
    let expectation = expectation(description: "completion fires once on empty input")
    DroppedURLs.resolve([]) { res in
      XCTAssertTrue(res.urls.isEmpty)
      XCTAssertTrue(res.errors.isEmpty)
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)
  }
}
