import Foundation
import AppKit

/// Shared collector for `onDrop(of: [.fileURL])` callbacks. The naive
/// pattern — mutating a single `var url: URL?` from background
/// `loadObject` closures — races on concurrent providers, drops every
/// URL past the first, and discards `loadObject` errors entirely (see
/// review v2 F2). This helper folds both the table drop site and the
/// AddModelSheet local-file pane onto one lock-guarded collector that
/// surfaces per-provider errors back to the caller.
enum DroppedURLs {

  /// Result of resolving a batch of dropped item providers. Callers
  /// inspect `errors` even when `urls` is non-empty — a partial
  /// failure (3 of 5 providers loaded) still warrants surfacing the
  /// two errors via the existing `actionError` slot.
  struct Resolution {
    let urls: [URL]
    let errors: [String]
  }

  /// Resolve every `NSItemProvider` in parallel, then call `completion`
  /// once on the main queue with the collected URLs + per-provider
  /// error strings. The completion is called exactly once even if
  /// individual `loadObject` callbacks fire on a background queue
  /// concurrently.
  static func resolve(_ providers: [NSItemProvider],
                       completion: @escaping (Resolution) -> Void) {
    guard !providers.isEmpty else {
      DispatchQueue.main.async { completion(Resolution(urls: [], errors: [])) }
      return
    }
    let lock = NSLock()
    var urls: [URL] = []
    var errors: [String] = []
    let group = DispatchGroup()
    for provider in providers {
      group.enter()
      _ = provider.loadObject(ofClass: URL.self) { received, loadError in
        lock.lock()
        if let received {
          urls.append(received)
        }
        if let loadError {
          errors.append(String(describing: loadError))
        }
        lock.unlock()
        group.leave()
      }
    }
    group.notify(queue: .main) {
      completion(Resolution(urls: urls, errors: errors))
    }
  }
}
