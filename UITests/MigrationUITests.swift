import XCTest

final class MigrationUITests: XCTestCase {
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testMigrationOnlyFlowAndPreferences() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-ui-demo"]; app.launch()
        XCTAssertTrue(app.buttons["sourceInstance"].waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "测试目标"), object: app.buttons["targetInstance"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        XCTAssertEqual(app.tabBars.count, 0)
        XCTAssertFalse(app.staticTexts["备份中心"].exists)
        shot("01-home-light")
        app.scrollViews.firstMatch.swipeUp()
        app.buttons["chooseDirectories"].tap()
        app.buttons["selectDirectory-Documents"].tap()
        shot("02-directory-selection")
        app.buttons["完成"].tap()
        app.buttons["nextStep"].tap()
        XCTAssertTrue(app.buttons["检查并继续"].isEnabled)
        shot("03-mapping")
        app.buttons["检查并继续"].tap()
        XCTAssertTrue(app.staticTexts["覆盖前确认"].waitForExistence(timeout: 15))
        shot("04-preview")
        app.scrollViews.firstMatch.swipeUp()
        app.switches["两个应用均已退出"].tap()
        app.switches["确认执行所选操作"].tap()
        app.buttons["开始迁移"].tap()
        XCTAssertTrue(app.alerts["执行所选文件操作？"].waitForExistence(timeout: 5))
        shot("20-centered-migration-confirmation")
        app.buttons["确认开始迁移"].tap()
        XCTAssertTrue(app.staticTexts["文件迁移完成"].waitForExistence(timeout: 20))
        shot("05-result")
        app.buttons["完成"].tap()
    }
    func testCompactHome() {
        let app = XCUIApplication(); app.launchArguments = ["-ui-demo"]; app.launch()
        XCTAssertTrue(app.buttons["sourceInstance"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["nextStep"].isHittable)
        XCTAssertEqual(app.tabBars.count, 0)
        shot("06-home-layout")
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(app.buttons["nextStep"].isHittable)
        shot("07-home-scrolled")
    }
    func testMergeSingleRootFile() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-ui-demo"]; app.launch()
        XCTAssertTrue(app.buttons["targetInstance"].waitForExistence(timeout: 15))
        app.segmentedControls["operationMode"].buttons["合并"].tap()
        app.scrollViews.firstMatch.swipeUp()
        app.buttons["chooseDirectories"].tap()
        XCTAssertTrue(app.buttons["selectDirectory-standalone.txt"].waitForExistence(timeout: 10))
        app.buttons["selectDirectory-standalone.txt"].tap()
        shot("08-file-selection")
        app.buttons["完成"].tap(); app.buttons["nextStep"].tap()
        XCTAssertTrue(app.buttons["检查并继续"].isEnabled); app.buttons["检查并继续"].tap()
        XCTAssertTrue(app.staticTexts["覆盖前确认"].waitForExistence(timeout: 10))
        app.scrollViews.firstMatch.swipeUp()
        app.switches["两个应用均已退出"].tap(); app.switches["确认执行所选操作"].tap()
        app.buttons["开始迁移"].tap(); app.buttons["确认开始迁移"].tap()
        XCTAssertTrue(app.staticTexts["文件迁移完成"].waitForExistence(timeout: 20))
        shot("09-merge-result"); app.buttons["完成"].tap()
    }
    func testExchangeRootFile() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-ui-demo"]; app.launch()
        XCTAssertTrue(app.buttons["targetInstance"].waitForExistence(timeout: 15))
        app.segmentedControls["operationMode"].buttons["转换"].tap()
        app.scrollViews.firstMatch.swipeUp(); app.buttons["chooseDirectories"].tap()
        app.buttons["selectDirectory-standalone.txt"].tap(); app.buttons["完成"].tap(); app.buttons["nextStep"].tap()
        XCTAssertTrue(app.buttons["检查并继续"].isEnabled); app.buttons["检查并继续"].tap()
        XCTAssertTrue(app.staticTexts["覆盖前确认"].waitForExistence(timeout: 10))
        app.scrollViews.firstMatch.swipeUp()
        app.switches["两个应用均已退出"].tap(); app.switches["确认执行所选操作"].tap()
        app.buttons["开始迁移"].tap(); app.buttons["确认开始迁移"].tap()
        XCTAssertTrue(app.staticTexts["文件迁移完成"].waitForExistence(timeout: 20))
        shot("10-exchange-result"); app.buttons["完成"].tap()
    }

    func testWholeApplicationRowAndNoWeChatHint() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-ui-demo"]; app.launch()
        XCTAssertTrue(app.buttons["targetInstance"].waitForExistence(timeout: 15))
        app.buttons["targetInstance"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "application-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "未确认 WeChat")).firstMatch.exists)
        shot("11-application-list")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["targetInstance"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["目标应用"].exists)
    }
    func testConfigurationImportZipAndApply() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-ui-demo", "-ui-config-import"]; app.launch()
        XCTAssertTrue(app.buttons["sourceInstance"].waitForExistence(timeout: 15))
        app.scrollViews.firstMatch.swipeUp()
        app.buttons["configurationLibrary"].tap()
        XCTAssertTrue(app.buttons["saveConfigurationChooseApp"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["更换备份保存位置"].exists)
        XCTAssertFalse(app.staticTexts["当前保存位置"].exists)
        let imported = app.staticTexts["UITestPlugin"].firstMatch
        if !imported.isHittable { app.swipeUp() }
        XCTAssertTrue(imported.waitForExistence(timeout: 15))
        shot("12-configuration-list")
        imported.tap()
        XCTAssertTrue(app.buttons["applySavedConfiguration"].waitForExistence(timeout: 5))
        app.buttons["applySavedConfiguration"].tap()
        app.buttons["configurationTarget"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "application-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        shot("13-configuration-apply")
        app.buttons["合并配置"].tap(); app.buttons["确认合并配置"].tap()
        XCTAssertTrue(app.staticTexts["配置已合并到所选应用"].waitForExistence(timeout: 20))
        shot("14-configuration-result"); app.buttons["完成"].tap()
    }
    func testSettingsHasNoFixtureCreator() {
        let app = XCUIApplication(); app.launchArguments = ["-ui-demo"]; app.launch()
        XCTAssertTrue(app.buttons["设置与记录"].waitForExistence(timeout: 15)); app.buttons["设置与记录"].tap()
        app.swipeUp(); XCTAssertFalse(app.buttons["创建可丢弃测试应用"].exists)
        XCTAssertFalse(app.staticTexts["配置副本位置"].exists)
        XCTAssertFalse(app.staticTexts["界面"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "supportedSystems").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "没有已保存的系统应用")).firstMatch.waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "1.0.0")).firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "telegramChannel").firstMatch.isHittable)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "sourceRepository").firstMatch.isHittable)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Xuegao")).firstMatch.exists)
        shot("15-settings")
    }

    func testIconCacheReadOnlyDiagnostic() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-ui-demo"]; app.launch()
        XCTAssertTrue(app.buttons["设置与记录"].waitForExistence(timeout: 15)); app.buttons["设置与记录"].tap()
        app.buttons["运行日志"].tap()
        let probe = app.buttons["检测图标缓存（只读）"]
        for _ in 0..<8 { if probe.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(probe.isHittable); probe.tap()
        XCTAssertTrue(app.buttons["复制完整诊断"].waitForExistence(timeout: 15))
        XCTAssertTrue((app.textViews["diagnosticBody"].value as? String)?.contains("未实现私有缓存解析或Bundle ID映射") == true)
        XCTAssertTrue(app.staticTexts["图标缓存探测完成"].exists)
        XCTAssertFalse(app.staticTexts["操作未完成"].exists)
        shot("21-icon-cache-diagnostic"); app.buttons["关闭"].tap()
    }

    func testLogSearchFilterAndDetail() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-ui-demo", "-ui-log-demo"]; app.launch()
        XCTAssertTrue(app.buttons["设置与记录"].waitForExistence(timeout: 15)); app.buttons["设置与记录"].tap()
        app.buttons["运行日志"].tap()
        XCTAssertTrue(app.textFields["logSearch"].waitForExistence(timeout: 5))
        shot("22-logs-overview")
        app.segmentedControls["logCategory"].buttons["异常"].tap()
        app.swipeUp()
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "logEntry-")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); shot("24-logs-filtered"); entry.tap()
        XCTAssertTrue(app.buttons["复制这条记录"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "errno=1")).firstMatch.exists)
        shot("23-log-detail"); app.buttons["关闭"].tap()
        app.swipeDown()
        app.segmentedControls["logCategory"].buttons["全部"].tap()
        let search = app.textFields["logSearch"]; search.tap(); search.typeText("does-not-exist")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["没有匹配的记录"].waitForExistence(timeout: 5))
    }

    func testZFailedProgressClipboard() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-ui-demo", "-ui-failed-progress"]; app.launch()
        let copy = app.buttons["复制诊断日志"]
        XCTAssertTrue(copy.waitForExistence(timeout: 15)); XCTAssertTrue(copy.isHittable)
        copy.tap()
        XCTAssertTrue(app.buttons["复制诊断日志"].label.contains("已复制完整诊断"))
        XCTAssertTrue(app.buttons["分享诊断日志"].isHittable)
        // Let the native button finish its title transition before recording visual evidence.
        Thread.sleep(forTimeInterval: 0.6)
        shot("25-failed-progress-copied")
    }

    func testManualPathAndRestoreDefault() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-ui-demo"]; app.launch()
        XCTAssertTrue(app.buttons["sourceInstance"].waitForExistence(timeout: 15))
        app.scrollViews.firstMatch.swipeUp(); app.buttons["chooseDirectories"].tap()
        app.buttons["selectDirectory-Documents"].tap(); app.buttons["完成"].tap(); app.buttons["nextStep"].tap()
        XCTAssertTrue(app.buttons["检查并继续"].isEnabled)
        XCTAssertFalse(app.buttons["samePath-Documents"].exists)
        app.buttons["manualPath-Documents"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Documents".count) + "tmp/custom")
        app.alerts.buttons["应用路径"].tap()
        XCTAssertTrue(app.buttons["samePath-Documents"].waitForExistence(timeout: 5))
        shot("16-custom-mapping"); app.buttons["samePath-Documents"].tap()
        XCTAssertFalse(app.buttons["samePath-Documents"].exists); shot("17-default-mapping")
    }
    func testManualConfigurationSaveWithoutHomeSelection() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-ui-demo", "-ui-no-selection"]; app.launch()
        XCTAssertTrue(app.buttons["sourceInstance"].waitForExistence(timeout: 15))
        app.scrollViews.firstMatch.swipeUp(); app.buttons["configurationLibrary"].tap()
        app.buttons["saveConfigurationChooseApp"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "application-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["插件配置已保存"].waitForExistence(timeout: 15))
        shot("18-manual-configuration-save"); app.buttons["完成"].tap()
    }

    func testDiagnosticCopyForInvalidMapping() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-ui-demo"]; app.launch()
        XCTAssertTrue(app.buttons["sourceInstance"].waitForExistence(timeout: 15))
        app.scrollViews.firstMatch.swipeUp(); app.buttons["chooseDirectories"].tap()
        app.buttons["selectDirectory-Documents"].tap(); app.buttons["完成"].tap(); app.buttons["nextStep"].tap()
        app.buttons["manualPath-Documents"].tap()
        let field = app.alerts.textFields.firstMatch; XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Documents".count) + "../outside")
        app.alerts.buttons["应用路径"].tap(); app.buttons["检查并继续"].tap()
        XCTAssertTrue(app.buttons["复制完整诊断"].waitForExistence(timeout: 10))
        XCTAssertTrue((app.textViews["diagnosticBody"].value as? String)?.contains("../outside") == true)
        shot("19-diagnostic"); app.buttons["复制完整诊断"].tap(); app.buttons["关闭"].tap()
    }

    func testNativeConfigurationPickerImportsFiles() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-ui-demo"]; app.launch()
        XCTAssertTrue(app.buttons["sourceInstance"].waitForExistence(timeout: 15))
        app.scrollViews.firstMatch.swipeUp(); app.buttons["configurationLibrary"].tap()
        for (file, name) in [("PickerBundle", "PickerBundle"), ("PickerPlugin", "PickerPlugin")] {
            app.buttons["importConfigurationFile"].tap()
            XCTAssertTrue(app.tabBars.buttons["浏览"].waitForExistence(timeout: 10))
            app.tabBars.buttons["浏览"].tap()
            let local = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "我的iPhone")).firstMatch
            if local.waitForExistence(timeout: 1) { local.tap() }
            let folder = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "WCMigrate-QA,")).firstMatch
            if folder.waitForExistence(timeout: 2) { folder.tap() }
            let item = app.cells.matching(NSPredicate(format: "label CONTAINS %@", file)).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 10), app.debugDescription); XCTAssertTrue(item.isEnabled)
            shot("26-native-picker-" + file)
            item.tap()
            let success = app.alerts["操作信息"]
            XCTAssertTrue(success.waitForExistence(timeout: 20), app.debugDescription)
            XCTAssertTrue(success.staticTexts["配置已导入，可选择应用执行替换或合并。"].exists)
            success.buttons["知道了"].tap()
            XCTAssertTrue(app.staticTexts[name].firstMatch.waitForExistence(timeout: 5))
            shot("27-imported-" + file)
        }
    }
    func testLargeDiagnosticVisibleInBothScreens() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-ui-demo", "-ui-long-diagnostic"]; app.launch()
        XCTAssertTrue(app.buttons["设置与记录"].waitForExistence(timeout: 15)); app.buttons["设置与记录"].tap()
        app.buttons["运行日志"].tap(); app.buttons["rawDiagnostics"].tap()
        app.buttons["查看原始授权与图标日志"].tap()
        let raw = app.textViews["rawDiagnosticBody"]
        XCTAssertTrue(raw.waitForExistence(timeout: 5)); XCTAssertTrue(raw.isHittable)
        XCTAssertTrue((raw.value as? String)?.contains("长日志测试 1") == true)
        app.buttons["rawDiagnosticBody-lastPage"].tap()
        XCTAssertTrue((raw.value as? String)?.contains("END-LONG-DIAGNOSTIC") == true)
        XCTAssertLessThanOrEqual(raw.frame.height, 361)
        shot("28-long-raw-diagnostic")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["检测图标缓存（只读）"].tap()
        let body = app.textViews["diagnosticBody"]
        XCTAssertTrue(body.waitForExistence(timeout: 15)); XCTAssertTrue(body.isHittable)
        let value = body.value as? String ?? ""
        XCTAssertTrue(value.contains("图标缓存只读探测"))
        app.buttons["diagnosticBody-lastPage"].tap()
        XCTAssertTrue((body.value as? String)?.contains("END-LONG-DIAGNOSTIC") == true)
        XCTAssertLessThan(body.frame.height, 700)
        app.buttons["复制完整诊断"].tap()
        XCTAssertTrue(app.buttons["复制完整诊断"].label.contains("已复制完整诊断"))
        shot("29-long-diagnostic-visible")
    }

    func testOperationStayAwakeProgressAndPlistToggle() {
        let app = XCUIApplication(); app.launchArguments = ["-ui-demo", "-ui-operation-progress"]; app.launch()
        XCTAssertTrue(app.staticTexts["stayOnOperationPage"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["35%"].exists)
        XCTAssertEqual(app.staticTexts["stayOnOperationPage"].value as? String, "屏幕常亮已开启")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "预计剩余")).firstMatch.exists)
        XCTAssertTrue(app.buttons["停止操作"].isHittable)
        shot("30-operation-progress")
        app.terminate(); app.launchArguments = ["-ui-demo"]; app.launch()
        XCTAssertTrue(app.buttons["sourceInstance"].waitForExistence(timeout: 15))
        app.scrollViews.firstMatch.swipeUp(); app.buttons["configurationLibrary"].tap()
        XCTAssertTrue(app.switches["backupPlistOnly"].waitForExistence(timeout: 5))
        app.switches["backupPlistOnly"].tap()
        shot("31-plist-only-toggle")
    }
    func testResumeInterruptedExchangeFromHistory() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-ui-demo", "-ui-resume-demo"]; app.launch()
        XCTAssertTrue(app.buttons["设置与记录"].waitForExistence(timeout: 15)); app.buttons["设置与记录"].tap()
        app.buttons["迁移记录"].tap()
        let resume = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "resumeMigration-")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 10)); shot("32-resume-history"); resume.tap()
        app.alerts.buttons["检查并继续"].tap()
        XCTAssertTrue(app.staticTexts["文件迁移完成"].waitForExistence(timeout: 15))
        shot("33-resume-result")
    }

}
