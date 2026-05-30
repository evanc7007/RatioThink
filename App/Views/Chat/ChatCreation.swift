import Foundation
import SwiftData

/// Shared "insert a fresh chat" path used by both the chat-list New Chat
/// affordance and the col-3 zero-state CTA. Centralizing it keeps the
/// save + rollback-on-failure behavior identical wherever a chat is
/// created — the in-memory insert is rolled back on a save error so the
/// `@Query`-backed sidebar never surfaces a row that is not on disk.
@available(macOS 14, *)
enum ChatCreation {
  /// Insert and persist a new chat, returning its id. On a save failure
  /// the insert is rolled back, the error is reported, and `nil` is
  /// returned so the caller leaves selection untouched.
  @MainActor
  static func create(
    in context: ModelContext,
    persistenceStatus: PersistenceStatus,
    contextLabel: String
  ) -> UUID? {
    let chat = Chat()
    context.insert(chat)
    do {
      try context.save()
    } catch {
      context.delete(chat)
      persistenceStatus.report(error, context: contextLabel)
      return nil
    }
    return chat.id
  }
}
