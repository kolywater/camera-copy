import XCTest

/// Clicks the real "Check for Updates…" menu item and "Install and Relaunch" button.
/// Run with `just test-ui`. It builds the app as version 1.0 so GitHub's latest release is offered,
/// and the update replaces the test copy of the app in build/ (never the one in /Applications).
/// Needs Accessibility permission for the test runner (System Settings > Privacy & Security).
final class UpdateButtonUITests: XCTestCase {
    func testInstallAndRelaunchReallyUpdatesTheApp() throws {
        let app = XCUIApplication()
        app.launch()
        app.menuBars.menuBarItems["Camera Copy"].click()
        app.menuItems["Check for Updates…"].click()
        let install = app.buttons["Install and Relaunch"]
        XCTAssertTrue(install.waitForExistence(timeout: 30), "an update should be offered to a 1.0 build")
        install.click()
        // The app quits itself so the helper can swap it; that's the whole point of the button.
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 60), "the app should quit to install the update")
    }
}
