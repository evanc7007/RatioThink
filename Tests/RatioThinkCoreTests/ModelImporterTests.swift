import XCTest
@testable import RatioThinkCore

/// Unit tests for `ModelImporter.importFile`. Covers the validation
/// gates (regular file, .gguf extension, no clobber) so the Settings
/// drop pane fails predictably and never silently overwrites a model.
final class ModelImporterTests: XCTestCase {

  func test_copies_gguf_into_dest_and_returns_destination_url() throws {
    try withScratchDirs { src, dest in
      let source = src.appendingPathComponent("model.gguf")
      try Data([0x01, 0x02, 0x03]).write(to: source)

      let url = try ModelImporter.importFile(at: source, into: dest)
      XCTAssertEqual(url.lastPathComponent, "model.gguf")
      XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
      // Source preserved
      XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                    "import must copy, not move — original file should stay put")
    }
  }

  func test_rejects_non_regular_file() throws {
    try withScratchDirs { src, dest in
      let dir = src.appendingPathComponent("notafile.gguf", isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      XCTAssertThrowsError(try ModelImporter.importFile(at: dir, into: dest)) { err in
        guard case ModelImporter.ImportError.notAFile = err else {
          XCTFail("expected .notAFile, got \(err)")
          return
        }
      }
    }
  }

  func test_rejects_non_gguf_extension() throws {
    try withScratchDirs { src, dest in
      let url = src.appendingPathComponent("model.bin")
      try Data([0x00]).write(to: url)
      XCTAssertThrowsError(try ModelImporter.importFile(at: url, into: dest)) { err in
        guard case ModelImporter.ImportError.wrongExtension = err else {
          XCTFail("expected .wrongExtension, got \(err)")
          return
        }
      }
    }
  }

  func test_refuses_to_clobber_existing_destination() throws {
    try withScratchDirs { src, dest in
      let source = src.appendingPathComponent("model.gguf")
      try Data([0x01]).write(to: source)
      try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
      try Data([0xFF]).write(to: dest.appendingPathComponent("model.gguf"))

      XCTAssertThrowsError(try ModelImporter.importFile(at: source, into: dest)) { err in
        guard case ModelImporter.ImportError.destinationExists = err else {
          XCTFail("expected .destinationExists, got \(err)")
          return
        }
      }
    }
  }

  func test_creates_destination_directory_if_missing() throws {
    let src = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("pie-importer-src-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: src) }

    let dest = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("pie-importer-dest-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("nested", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }

    let source = src.appendingPathComponent("model.gguf")
    try Data([0xAA]).write(to: source)
    let url = try ModelImporter.importFile(at: source, into: dest)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
  }

  // MARK: - helpers

  private func withScratchDirs(_ body: (URL, URL) throws -> Void) throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-importer-\(UUID().uuidString)", isDirectory: true)
    let src = root.appendingPathComponent("src", isDirectory: true)
    let dest = root.appendingPathComponent("models", isDirectory: true)
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    var bodyError: Error?
    do { try body(src, dest) } catch { bodyError = error }
    try FileManager.default.removeItem(at: root)
    if let bodyError { throw bodyError }
  }
}
