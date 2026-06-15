import XCTest

// To exercise your app's own code, import its module. The module name matches
// the `name:` in project.yml (default: AppName):
//
//   @testable import AppName
//
// Then assert against your types. The self-contained tests below pass out of
// the box so `Unit Tests (Simulator)` is green from the first commit.

final class AppNameTests: XCTestCase {
  func testArithmeticSanity() {
    XCTAssertEqual(2 + 2, 4)
  }

  func testTapLabelPluralization() {
    func label(_ count: Int) -> String {
      "You tapped \(count) time\(count == 1 ? "" : "s")."
    }
    XCTAssertEqual(label(1), "You tapped 1 time.")
    XCTAssertEqual(label(3), "You tapped 3 times.")
  }
}
