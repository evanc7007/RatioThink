import XCTest
import RatioThinkCore
@testable import Scenarios

final class S3EngineSubprocessTests: XCTestCase {
  func test_chatCompletionDrain_accepts_length_finish_after_semantic_delta() async throws {
    let stream = AsyncThrowingStream<ChatEvent, Error> { continuation in
      continuation.yield(.delta(role: nil, content: "The capital of France is Paris."))
      continuation.yield(.finish(reason: .length))
      continuation.finish()
    }

    let tokens = try await S3_EngineSubprocess.drainChatCompletion(
      CLIRunner(),
      events: stream,
      timeoutSeconds: 1,
      label: "chat-test"
    )

    XCTAssertTrue(tokens.contains("Paris"))
  }

  func test_chatCompletionDrain_rejects_length_finish_without_semantic_answer() async throws {
    let stream = AsyncThrowingStream<ChatEvent, Error> { continuation in
      continuation.yield(.delta(role: nil, content: "This is a long but irrelevant truncated answer."))
      continuation.yield(.finish(reason: .length))
      continuation.finish()
    }

    do {
      _ = try await S3_EngineSubprocess.drainChatCompletion(
        CLIRunner(),
        events: stream,
        timeoutSeconds: 1,
        label: "chat-test"
      )
      XCTFail("expected .length without the semantic Paris answer to fail")
    } catch ScenarioError.assertionFailed(let message, _, _) {
      XCTAssertTrue(message.contains("finish_reason=.length"),
                    "failure should explain the stricter .length semantic gate: \(message)")
    }
  }

  func test_chatCompletionDrain_timesOut_before_delayed_finish() async throws {
    let stream = AsyncThrowingStream<ChatEvent, Error> { continuation in
      Task {
        continuation.yield(.delta(role: nil, content: "Paris"))
        try? await Task.sleep(nanoseconds: 200_000_000)
        continuation.yield(.finish(reason: .stop))
        continuation.finish()
      }
    }

    do {
      _ = try await S3_EngineSubprocess.drainChatCompletion(
        CLIRunner(),
        events: stream,
        timeoutSeconds: 0.01,
        label: "chat-test"
      )
      XCTFail("expected ScenarioError.timeout before delayed stream finish")
    } catch ScenarioError.timeout(let message) {
      XCTAssertTrue(message.contains("chat-test"),
                    "timeout message should identify the chat drain: \(message)")
    }
  }
}
