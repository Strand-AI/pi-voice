import XCTest

final class PiVoicePhoneUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFakeVoiceShowsBoundedCaptionsMuteAndRouteControlsWithoutRealMedia() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-test-preferences", "--fake-voice", "--fake-long-caption"]
        app.launch()

        let status = app.staticTexts["connectionStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Ready — microphone and billing are off")
        XCTAssertTrue(app.staticTexts["fakeModeBadge"].exists)

        let picker = app.buttons["agentPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 2))
        picker.tap()
        app.buttons["Simulator Pi"].tap()

        let start = app.buttons["startVoiceButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 2))
        start.tap()

        let mute = app.buttons["microphoneMuteButton"]
        XCTAssertTrue(mute.waitForExistence(timeout: 2))
        XCTAssertEqual(mute.label, "Mute microphone")
        mute.tap()
        XCTAssertEqual(mute.label, "Unmute microphone")
        XCTAssertTrue(mute.isEnabled)
        XCTAssertTrue(app.staticTexts["Muted"].firstMatch.waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["microphoneMuteState"].exists)

        let route = app.buttons["audioRouteButton"]
        XCTAssertTrue(route.exists)
        XCTAssertFalse(route.isEnabled)
        XCTAssertFalse(app.switches["speakerphoneToggle"].exists)
        XCTAssertFalse(app.staticTexts["Output"].exists)

        let caption = app.staticTexts["recentPiCaption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 2))
        let captionPrefix = caption.label.hasPrefix("Pi, current caption: ") ? "Pi, current caption: " : "Pi: "
        XCTAssertTrue(caption.label.hasPrefix(captionPrefix))
        XCTAssertEqual(caption.label.dropFirst(captionPrefix.count).count, 500)
        XCTAssertTrue(caption.label.hasSuffix("🙂"))
    }

    func testFakePoorNetworkShowsReconnectingAndRequiresFreshPTTGesture() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-test-preferences", "--fake-voice", "--fake-ice-disconnect", "--fake-ice-recover"]
        app.launch()

        let picker = app.buttons["agentPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        sleep(1)
        picker.tap()
        XCTAssertTrue(app.buttons["Simulator Pi"].waitForExistence(timeout: 2))
        app.buttons["Simulator Pi"].tap()
        app.buttons["Push to talk"].tap()
        app.buttons["startVoiceButton"].tap()

        let status = app.staticTexts["connectionStatus"]
        let reconnecting = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH 'Reconnecting audio'"),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [reconnecting], timeout: 3), .completed)
        let ptt = app.descendants(matching: .any)["pttSurface"]
        XCTAssertTrue(ptt.waitForExistence(timeout: 2))
        XCTAssertEqual(ptt.value as? String, "Unavailable while audio reconnects")

        let live = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH 'Live'"),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [live], timeout: 6), .completed)
        XCTAssertEqual(ptt.value as? String, "Ready")
    }

    func testExactClosureReceiptReturnsReadyWithoutAutomaticallyStartingVoice() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-test-preferences", "--fake-voice", "--fake-control-loss", "--fake-provider-closed-receipt"]
        app.launch()

        let picker = app.buttons["agentPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        sleep(1)
        picker.tap()
        XCTAssertTrue(app.buttons["Simulator Pi"].waitForExistence(timeout: 2))
        app.buttons["Simulator Pi"].tap()
        app.buttons["startVoiceButton"].tap()

        let check = app.buttons["retryClosureCheckButton"]
        XCTAssertTrue(check.waitForExistence(timeout: 3))
        check.tap()

        let status = app.staticTexts["connectionStatus"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Ready — microphone and billing are off'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 3), .completed)
        XCTAssertTrue(app.buttons["startVoiceButton"].exists, "closure recovery automatically started a replacement provider session")
        XCTAssertFalse(app.buttons["retryClosureCheckButton"].exists)
    }

    func testLastAgentAndVoiceRestoreOnlyAfterFreshRosterWithoutAutoStart() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-test-preferences", "--fake-voice"]
        app.launch()
        let status = app.staticTexts["connectionStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Ready — microphone and billing are off")
        sleep(1)
        app.buttons["agentPicker"].tap()
        XCTAssertTrue(app.buttons["Simulator Pi"].waitForExistence(timeout: 2))
        app.buttons["Simulator Pi"].tap()
        app.swipeUp()
        let voicePicker = app.buttons["Voice, Marin"]
        let voicePickerHittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: voicePicker)
        XCTAssertEqual(XCTWaiter.wait(for: [voicePickerHittable], timeout: 2), .completed)
        voicePicker.tap()
        XCTAssertTrue(app.buttons["Bossa"].waitForExistence(timeout: 2))
        app.buttons["Bossa"].tap()
        app.terminate()

        app.launchArguments = ["--fake-voice"]
        app.launch()
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let restoredAgent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Simulator Pi'"), object: app.buttons["agentPicker"])
        XCTAssertEqual(XCTWaiter.wait(for: [restoredAgent], timeout: 3), .completed)
        XCTAssertTrue(app.buttons["Voice, Bossa"].exists)
        XCTAssertEqual(status.label, "Ready — microphone and billing are off")
        XCTAssertTrue(app.buttons["startVoiceButton"].isEnabled, "fresh selection was not restored")
        sleep(1)
        XCTAssertEqual(status.label, "Ready — microphone and billing are off", "restored preferences automatically started voice")
    }

    func testSavedCredentialReconnectDoesNotPresentTokenAsRequired() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-test-preferences", "--fake-voice", "--fake-saved-disconnected"]
        app.launch()

        XCTAssertEqual(app.staticTexts["connectionStatus"].label, "Not connected")
        XCTAssertFalse(app.secureTextFields["pairingTokenField"].exists)
        let reconnect = app.buttons["connectButton"]
        XCTAssertEqual(reconnect.label, "Reconnect")
        XCTAssertTrue(reconnect.isEnabled)
        XCTAssertTrue(app.buttons["repairPairingButton"].exists)
        XCTAssertFalse(app.buttons["startVoiceButton"].exists)
    }

    func testRealInitialScreenRejectsInvalidOriginLocally() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-test-preferences"]
        app.launch()

        XCTAssertTrue(app.staticTexts["connectionStatus"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["connectionStatus"].label, "Not connected")
        XCTAssertFalse(app.staticTexts["fakeModeBadge"].exists)
        XCTAssertFalse(app.staticTexts["voiceSafetyNotice"].exists)
        XCTAssertFalse(app.buttons["startVoiceButton"].exists)

        let origin = app.textFields["gatewayOriginField"]
        let token = app.secureTextFields["pairingTokenField"]
        let connect = app.buttons["connectButton"]
        XCTAssertTrue(origin.exists)
        XCTAssertTrue(token.exists)
        XCTAssertEqual(origin.value as? String, "https://private-gateway.example")
        XCTAssertEqual(token.value as? String, "New one-use pairing token")
        XCTAssertEqual(connect.label, "Pair")
        XCTAssertFalse(connect.isEnabled)

        token.tap()
        token.typeText(String(repeating: "a", count: 32))
        origin.tap()
        let currentValue = origin.value as? String ?? ""
        origin.typeText(currentValue.contains("private-gateway.example") ? "not-a-url" : "/not-allowed")
        XCTAssertTrue(connect.isEnabled)
        connect.tap()

        let error = app.staticTexts["formErrorText"]
        XCTAssertTrue(error.waitForExistence(timeout: 2))
        XCTAssertEqual(error.label, "Use the exact private HTTPS gateway origin.")
        XCTAssertEqual(app.staticTexts["connectionStatus"].label, "Not connected")
        XCTAssertFalse(app.buttons["startVoiceButton"].exists)
    }
}
