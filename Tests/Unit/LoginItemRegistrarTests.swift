import XCTest
@testable import RatioThink

final class LoginItemRegistrarTests: XCTestCase {
  func test_requiresApproval_is_not_treated_as_helper_ready() {
    XCTAssertFalse(
      LoginItemRegistrationStatus.requiresApproval.canContinue,
      "first launch must not proceed as though RatioThinkHelper is ready while macOS still requires approval"
    )
    XCTAssertTrue(LoginItemRegistrationStatus.enabled.canContinue)
  }
}
