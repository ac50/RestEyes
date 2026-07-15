import XCTest
@testable import RestEyesCore

final class ConfigTests: XCTestCase {

    // 默认值
    func testDefaults() {
        let c = Config()
        XCTAssertEqual(c.workMinutes, 20)
        XCTAssertEqual(c.restMinutes, 3)
        XCTAssertEqual(c.warnSeconds, 10)
        XCTAssertEqual(c.unlockAfter, .seconds(60))
        XCTAssertEqual(c.message, "休息一下,眺望远方 🌿")
        XCTAssertTrue(c.showCountdown)
        XCTAssertTrue(c.lockAfterRest)
        XCTAssertTrue(c.wakeEndsRest)
        XCTAssertTrue(c.launchAtLogin)
    }

    func testParseEmptyTextGivesDefaults() {
        XCTAssertEqual(Config.parse(""), Config())
    }

    // 完整解析
    func testParseFullConfig() {
        let text = """
        work_minutes = 45
        rest_minutes = 5.5
        warn_seconds = 0
        unlock_after = never
        message = 站起来走走
        show_countdown = off
        """
        let c = Config.parse(text)
        XCTAssertEqual(c.workMinutes, 45)
        XCTAssertEqual(c.restMinutes, 5.5)
        XCTAssertEqual(c.warnSeconds, 0)
        XCTAssertEqual(c.unlockAfter, .never)
        XCTAssertEqual(c.message, "站起来走走")
        XCTAssertFalse(c.showCountdown)
    }

    // 注释、空行、行尾注释
    func testCommentsAndBlankLinesIgnored() {
        let text = """
        # 整行注释

        work_minutes = 30   # 行尾注释
          # 缩进注释
        """
        let c = Config.parse(text)
        XCTAssertEqual(c.workMinutes, 30)
        XCTAssertEqual(c.restMinutes, 3)  // 其余默认
    }

    // 未知键忽略
    func testUnknownKeysIgnored() {
        let c = Config.parse("nonsense_key = 42\nwork_minutes = 15")
        XCTAssertEqual(c.workMinutes, 15)
        XCTAssertEqual(c, {
            var d = Config(); d.workMinutes = 15; return d
        }())
    }

    // 非法值回退默认
    func testInvalidValuesFallBackToDefaults() {
        let text = """
        work_minutes = abc
        rest_minutes = -1
        warn_seconds = 3.5
        unlock_after = maybe
        show_countdown = yes
        """
        XCTAssertEqual(Config.parse(text), Config())
    }

    // 越界回退默认
    func testOutOfRangeValuesFallBackToDefaults() {
        let text = """
        work_minutes = 0
        rest_minutes = 1441
        warn_seconds = 601
        unlock_after = 86401
        """
        XCTAssertEqual(Config.parse(text), Config())
    }

    // 边界值本身合法
    func testBoundaryValuesAccepted() {
        let text = """
        work_minutes = 1440
        rest_minutes = 0.1
        warn_seconds = 600
        unlock_after = 0
        """
        let c = Config.parse(text)
        XCTAssertEqual(c.workMinutes, 1440)
        XCTAssertEqual(c.restMinutes, 0.1)
        XCTAssertEqual(c.warnSeconds, 600)
        XCTAssertEqual(c.unlockAfter, .seconds(0))
    }

    // message 出现即采用,空串 = 纯黑屏
    func testEmptyMessageMeansBlackScreen() {
        let c = Config.parse("message =")
        XCTAssertEqual(c.message, "")
    }

    func testMessageAbsentKeepsDefault() {
        XCTAssertEqual(Config.parse("work_minutes = 10").message, Config().message)
    }

    // value 含 = 号(首个 = 分割)
    func testValueContainingEquals() {
        let c = Config.parse("message = a = b")
        XCTAssertEqual(c.message, "a = b")
    }

    // 默认文件内容与默认值往返一致
    func testDefaultFileContentRoundTrips() {
        XCTAssertEqual(Config.parse(Config.defaultFileContent), Config())
    }

    // load:不存在则创建默认文件
    func testLoadCreatesDefaultFileWhenMissing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resteyes-test-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("sub/config.txt")
        defer { try? FileManager.default.removeItem(at: dir) }

        let c = Config.load(from: url)
        XCTAssertEqual(c, Config())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                       Config.defaultFileContent)
    }

    // load:存在则解析
    func testLoadParsesExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resteyes-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.txt")
        defer { try? FileManager.default.removeItem(at: dir) }

        try "work_minutes = 50".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(Config.load(from: url).workMinutes, 50)
    }

    // defaultURL 指向 ~/.config/resteyes/config.txt
    func testDefaultURL() {
        XCTAssertTrue(Config.defaultURL.path.hasSuffix("/.config/resteyes/config.txt"))
    }

    // CRLF 行尾也能解析
    func testCRLFLineEndingsParsed() {
        let c = Config.parse("work_minutes = 30\r\nrest_minutes = 5\r\n")
        XCTAssertEqual(c.workMinutes, 30)
        XCTAssertEqual(c.restMinutes, 5)
    }

    // 孤立 \r(旧 Mac 行尾)也能解析
    func testLoneCRLineEndingsParsed() {
        let c = Config.parse("work_minutes = 30\rrest_minutes = 5\r")
        XCTAssertEqual(c.workMinutes, 30)
        XCTAssertEqual(c.restMinutes, 5)
    }

    // lock_after_rest 解析:on/off/非法值回退
    func testLockAfterRestParsing() {
        XCTAssertFalse(Config.parse("lock_after_rest = off").lockAfterRest)
        XCTAssertTrue(Config.parse("lock_after_rest = on").lockAfterRest)
        XCTAssertTrue(Config.parse("lock_after_rest = yes").lockAfterRest)
        XCTAssertTrue(Config.parse("").lockAfterRest)
    }

    // wake_ends_rest 解析:on/off/非法值回退
    func testWakeEndsRestParsing() {
        XCTAssertFalse(Config.parse("wake_ends_rest = off").wakeEndsRest)
        XCTAssertTrue(Config.parse("wake_ends_rest = on").wakeEndsRest)
        XCTAssertTrue(Config.parse("wake_ends_rest = 1").wakeEndsRest)
        XCTAssertTrue(Config.parse("").wakeEndsRest)
    }

    // launch_at_login 解析:on/off/非法值回退
    func testLaunchAtLoginParsing() {
        XCTAssertFalse(Config.parse("launch_at_login = off").launchAtLogin)
        XCTAssertTrue(Config.parse("launch_at_login = on").launchAtLogin)
        XCTAssertTrue(Config.parse("launch_at_login = maybe").launchAtLogin)
        XCTAssertTrue(Config.parse("").launchAtLogin)
    }

    func testLockOnUnlockDefaultsOn() {
        XCTAssertTrue(Config().lockOnUnlock)
    }

    func testLockOnUnlockParsesOff() {
        XCTAssertFalse(Config.parse("lock_on_unlock = off").lockOnUnlock)
    }

    func testLockOnUnlockParsesOn() {
        XCTAssertTrue(Config.parse("lock_on_unlock = on").lockOnUnlock)
    }

    func testLockOnUnlockInvalidFallsBackToDefault() {
        XCTAssertTrue(Config.parse("lock_on_unlock = maybe").lockOnUnlock)
    }
}
