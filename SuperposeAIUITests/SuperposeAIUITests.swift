import XCTest

final class SuperposeAIUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOnboardingScreenAppears() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestingResetOnboarding"]
        app.launch()

        XCTAssertTrue(app.buttons.firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testMainTabBarNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestingSkipOnboarding"]
        addUIInterruptionMonitor(withDescription: "System Permission Dialog") { alert in
            let allowButtons = ["OK", "Allow", "İzin Ver"]
            for title in allowButtons where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        app.launch()

        let libraryTab = app.buttons["Library"].waitForExistence(timeout: 8)
            ? app.buttons["Library"]
            : app.buttons["Kütüphane"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 5))
        libraryTab.tap()
        XCTAssertTrue(
            app.navigationBars["Library"].waitForExistence(timeout: 5)
            || app.navigationBars["Kütüphane"].waitForExistence(timeout: 2)
        )

        let settingsTab = app.buttons["Settings"].exists ? app.buttons["Settings"] : app.buttons["Ayarlar"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        let cameraTab = app.buttons["Camera"].exists ? app.buttons["Camera"] : app.buttons["Kamera"]
        XCTAssertTrue(cameraTab.waitForExistence(timeout: 5))
        cameraTab.tap()
    }
}
