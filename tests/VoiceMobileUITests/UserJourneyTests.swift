import XCTest

@MainActor final class UserJourneyTests: XCTestCase {
    let app = XCUIApplication()
    let server = "https://localhost:18865"
    var caseID = UUID().uuidString

    func control(_ value: [String: Any]) async throws {
        var request = URLRequest(url:URL(string:server+"/__control")!)
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject:value)
        request.timeoutInterval = 10
        let (_,response) = try await URLSession.shared.data(for:request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
    }
    func state() async throws -> [String: Any] {
        var request = URLRequest(url: URL(string:server+"/__state")!)
        request.timeoutInterval = 10
        let (data,_) = try await URLSession.shared.data(for: request)
        return try JSONSerialization.jsonObject(with:data) as! [String:Any]
    }
    func start() async throws {
        continueAfterFailure = false
        if app.state != .notRunning { app.terminate() }
        try await control(["reset":true])
        app.launchArguments = ["--ui-test-server",server+"/voice","--ui-test-case",caseID]
        app.launch()
        XCTAssertTrue(app.buttons["library.new-recording"].waitForExistence(timeout:15))
    }
    func record(_ title: String) {
        app.buttons["library.new-recording"].tap()
        let field = app.textFields["recording.title"]
        XCTAssertTrue(field.waitForExistence(timeout:5)); field.tap(); field.typeText(title)
        app.buttons["録音開始"].tap()
        XCTAssertTrue(app.buttons["recording.finish"].firstMatch.waitForExistence(timeout:10))
    }
    func waitForText(_ text: String, timeout: TimeInterval = 20) async {
        let view = app.textViews["result.text"]
        XCTAssertTrue(view.waitForExistence(timeout:timeout))
        let predicate = NSPredicate(format:"value CONTAINS %@",text)
        let appeared = XCTNSPredicateExpectation(predicate: predicate, object: view)
        let result = await XCTWaiter.fulfillment(of: [appeared], timeout: timeout)
        XCTAssertEqual(result, .completed)
    }
    func waitForCheckpoint() async {
        let clock = app.staticTexts["recording.time"]
        let recorded = NSPredicate { element, _ in
            guard let value = element as? XCUIElement else { return false }
            let parts = value.label.split(separator:":").compactMap { Int($0) }
            return !parts.isEmpty && parts.reduce(0, { $0*60+$1 }) >= 11
        }
        let checkpoint = XCTNSPredicateExpectation(predicate: recorded, object: clock)
        let result = await XCTWaiter.fulfillment(of: [checkpoint], timeout: 40)
        XCTAssertEqual(result, .completed)
    }
    func openLibrary() {
        if !app.buttons["library.open-recording"].exists && !app.buttons["library.new-recording"].exists {
            app.navigationBars.buttons.element(boundBy:0).tap()
        }
    }
    func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot:app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
    func pick(_ title: String) {
        let button = app.buttons[title]
        if button.exists { button.tap() }
        else { app.buttons.matching(NSPredicate(format:"label CONTAINS %@",title)).firstMatch.tap() }
    }
    func testNamedRecordingPauseResumeUploadCopyAndSummaries() async throws {
        try await start(); record("Lecture Notes")
        try await Task.sleep(nanoseconds:1_100_000_000)
        app.buttons["recording.pause"].firstMatch.tap()
        XCTAssertTrue(app.buttons["recording.resume"].waitForExistence(timeout:5))
        app.buttons["recording.resume"].tap()
        XCTAssertTrue(app.staticTexts["recording.time"].waitForExistence(timeout:5))
        XCTAssertLessThan(app.staticTexts["recording.time"].frame.height,80)
        app.buttons["recording.finish"].firstMatch.tap()
        await waitForText("図書館")
        app.buttons["result.copy"].tap()
        XCTAssertEqual(app.buttons["result.copy"].value as? String,"コピー済み")
        shot("original-and-copy")
        for (action, expected) in [("丁寧にする","読みやすく"),("3行程度に要約","次回まで"),("詳しく要約","詳しい要約")] {
            app.buttons["result.generate"].tap(); pick(action); await waitForText(expected)
        }
        let result = try await state()
        XCTAssertEqual((result["jobs"] as? [String:Any])?.count,1)
        XCTAssertTrue((result["events"] as! [[String:Any]]).allSatisfy { $0["backend"] as? String == "local" })
        shot("detailed-summary")
        app.buttons["result.mode"].tap(); pick("文字起こし"); await waitForText("図書館")
    }
    func testReturnToLibraryDuringRecordingAndStop() async throws {
        try await start(); record("Background List")
        openLibrary()
        XCTAssertTrue(app.buttons["library.open-recording"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["recording.finish"].firstMatch.isHittable)
        let before = try await state()
        XCTAssertTrue((before["uploads"] as! [Any]).isEmpty)
        shot("recording-list")
        app.buttons["library.open-recording"].tap()
        XCTAssertTrue(app.staticTexts["recording.time"].waitForExistence(timeout:5))
        app.buttons["recording.finish"].firstMatch.tap(); await waitForText("図書館")
    }
    func testConnectionFailureKeepsAudioAndRetryWorks() async throws {
        try await start(); record("Offline Retry")
        try await Task.sleep(nanoseconds:500_000_000)
        try await control(["offline":true])
        app.buttons["recording.finish"].firstMatch.tap()
        let alert = app.alerts["お知らせ"]
        XCTAssertTrue(alert.waitForExistence(timeout:15))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","サーバー応答の確認")).firstMatch.exists)
        shot("offline-diagnostic")
        alert.buttons["OK"].tap()
        try await control(["offline":false])
        XCTAssertTrue(app.buttons["recording.send"].waitForExistence(timeout:5))
        app.buttons["recording.send"].tap(); await waitForText("図書館")
        let result = try await state()
        XCTAssertEqual((result["jobs"] as! [String:Any]).count,1)
    }
    func testTerminateDuringRecordingReopenAndResume() async throws {
        try await start(); record("Recovered Lecture")
        await waitForCheckpoint()
        let before = try await state()
        XCTAssertTrue((before["uploads"] as! [Any]).isEmpty)
        app.terminate(); app.launch()
        let row = app.cells.containing(.staticText,identifier:"Recovered Lecture").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:10)); row.tap()
        XCTAssertTrue(app.buttons["recording.resume"].waitForExistence(timeout:5))
        app.buttons["recording.resume"].tap()
        XCTAssertTrue(app.buttons["recording.finish"].firstMatch.waitForExistence(timeout:5))
        app.buttons["recording.finish"].firstMatch.tap(); await waitForText("図書館")
        let result = try await state()
        let uploads = result["uploads"] as! [[String:Any]]
        XCTAssertGreaterThanOrEqual(uploads.last!["seconds"] as! Double,10)
        shot("recovered-after-termination")
    }
    func testSwipeDeleteAndRestoreLocalRecording() async throws {
        try await start(); record("Keep My Audio")
        app.buttons["recording.pause"].firstMatch.tap()
        openLibrary()
        let row = app.cells.containing(.staticText,identifier:"Keep My Audio").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:5)); row.swipeLeft(); app.buttons["削除"].firstMatch.tap()
        app.buttons["library.menu"].tap(); pick("最近削除した項目")
        XCTAssertTrue(row.waitForExistence(timeout:5)); row.swipeLeft()
        app.buttons["完全に削除"].firstMatch.tap()
        let cancel = app.buttons["キャンセル"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout:5)); cancel.tap()
        XCTAssertTrue(row.exists)
        if !app.buttons["復元"].firstMatch.isHittable { row.swipeLeft() }
        app.buttons["復元"].firstMatch.tap()
        app.buttons["library.menu"].tap(); pick("この端末")
        XCTAssertTrue(row.waitForExistence(timeout:5)); row.tap()
        XCTAssertTrue(app.buttons["recording.resume"].waitForExistence(timeout:5))
        shot("restored-local-recording")
    }
    func testPlaybackSeeksAcrossSegmentsAndFinishesAtTotalTime() async throws {
        try await start(); record("Playback Timeline")
        await waitForCheckpoint()
        app.buttons["recording.pause"].firstMatch.tap(); app.buttons["recording.resume"].tap()
        try await Task.sleep(nanoseconds:500_000_000)
        app.buttons["recording.finish"].firstMatch.tap(); await waitForText("図書館")
        let result = try await state(), uploads = result["uploads"] as! [[String:Any]]
        let seconds = Int(uploads.last!["seconds"] as! Double)
        let total = String(format:"%02d:%02d",seconds/60,seconds%60)
        let slider = app.sliders["playback.seek"]
        XCTAssertTrue(slider.exists)
        let displayedDuration = app.staticTexts["playback.duration"]
        XCTAssertTrue(displayedDuration.exists)
        XCTAssertEqual(displayedDuration.label, total)
        slider.adjust(toNormalizedSliderPosition:0.2)
        let play = app.buttons["playback.play"]
        play.tap(); XCTAssertEqual(play.value as? String,"再生中")
        play.tap(); XCTAssertEqual(play.value as? String,"停止中")
        slider.adjust(toNormalizedSliderPosition:0.98); play.tap()
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format:"value == %@","停止中"), object: play)
        let reachedEnd = await XCTWaiter.fulfillment(of: [stopped], timeout: 15)
        XCTAssertEqual(reachedEnd, .completed)
        XCTAssertEqual(app.staticTexts["playback.elapsed"].label, total)
        shot("playback-at-the-end")
    }
}
