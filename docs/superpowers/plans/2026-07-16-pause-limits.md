# 限制连续暂停/跳过 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让「暂停 1 小时」和「跳过下次休息」在连续使用若干次后被禁用,必须先完整休息一次才能再用。

**Architecture:** `BreakScheduler` 内加一个 `consecutiveSkips: Int` 计数器:暂停/跳过**生效时** `+1`,休息**跑满时**归零,没跑满时 `+1`(即掐断休息本身也算逃避)。达 `max_consecutive_skips` 后 `pause()` 与跳过消费点双双拒绝。不新增类型、不新增文件、不看时钟、不落盘。

**Tech Stack:** Swift 5.10 / SwiftPM / XCTest / AppKit(仅胶水层)。零第三方依赖。

依据 spec:[`docs/superpowers/specs/2026-07-16-pause-limits-design.md`](../specs/2026-07-16-pause-limits-design.md)

## Global Constraints

- **本地无法编译或测试**:开发机是 Linux,无 Swift 工具链。每个「验证」步骤 = commit + push + 确认 GitHub Actions 的 `swift test` 与 build job 绿。`gh` 命令必须加前缀 `GH_CONFIG_DIR=/home/paha/CCWorkspace/cloneWorkToRevise/RestEyes/.gh-config`;`git push` 不需要前缀。该网络偶发 TLS handshake timeout,重试即可。
- **`RestEyesCore` 不 import AppKit**,内部**零 `Date()` 调用**,时间一律由 `now: Date` 参数注入。这是它可测试的根基,任何改动不得破坏。
- **胶水层(`main.swift` / `StatusItem.swift`)不做单测**,其门槛是 CI build 绿 + 各任务列出的手动验收项。
- **配置解析风格**:手写 `key = value`,逐键校验、非法值回退默认、绝不抛错。新键必须同风格。
- **既有 30+ 条单测必须全部保持绿**。本计划的重构(`endRest` / `advancePastWorkDeadline` / `reload`)只在 spec 明示处改变行为。
- 新配置键与默认值(逐字照抄 spec):
  - `max_consecutive_skips = 2` —— 校验范围 `0...100`,`0` = 不限,`1` = 不允许连续
  - `require_full_rest = on` —— `on`/`off`,非法值回退 `on`
- 超限菜单文案(逐字):`(已达连续上限,请先完成一次休息)`

## File Structure

| 文件 | 动作 | 职责 |
|---|---|---|
| `Sources/RestEyesCore/Config.swift` | Modify | 加两个字段、两个 `case`、`defaultFileContent` 两行 |
| `Sources/RestEyesCore/BreakScheduler.swift` | Modify | 计数器、`skipsExhausted`、`pause() -> Bool`、`endRest`、`advancePastWorkDeadline`、`systemDidWake` 改造、`reload` 收紧、`TickInfo` 加字段 |
| `Sources/RestEyes/StatusItem.swift` | Modify | `update` 增参;两项的标题与 `isEnabled` |
| `Sources/RestEyes/main.swift` | Modify | 两处:`onTick` 增传参;`reconcileIfBack` 的 `.paused` 分支 |
| `Tests/RestEyesCoreTests/ConfigTests.swift` | Modify | 新键解析、`= 0` 出口、`defaultFileContent` 可证伪断言 |
| `Tests/RestEyesCoreTests/BreakSchedulerTests.swift` | Modify | 计数、拒绝、清零/`+1`、跳过两入口、`reload` 回归 |
| `Resources/Info.plist` | Modify | `0.1.11` → `0.1.12`,build `12` → `13` |
| `README.md` | Modify | 配置表两行、已知边界、手动验收清单 |

**不新增任何类型或文件。** 早期设计曾计划独立的 `PauseBudget`,理由是「滚动窗口数学与状态机正交」;改用连续计数模型后窗口数学消失,剩下一个 `Int` 加三行判断,独立成型即过度设计(见 spec「为什么不独立成型」)。

**不改**:`Format.swift`、`OverlayController.swift`、`ScreenLocker.swift`、`LoginItem.swift`、`.github/workflows/build.yml`。

---

## Task 1: Config 加 `max_consecutive_skips` 与 `require_full_rest`

**Files:**
- Modify: `Sources/RestEyesCore/Config.swift`
- Test: `Tests/RestEyesCoreTests/ConfigTests.swift`

**Interfaces:**
- Consumes: 无(首个任务)
- Produces: `Config.maxConsecutiveSkips: Int`(默认 `2`)、`Config.requireFullRest: Bool`(默认 `true`)。Task 2–6 全部依赖这两个字段。

- [ ] **Step 1: 写失败的测试**

追加到 `Tests/RestEyesCoreTests/ConfigTests.swift` 的 `ConfigTests` 类里(放在 `testLockOnUnlockInvalidFallsBackToDefault` 之后、类的右大括号之前):

```swift
    // 连续限制:默认值
    func testConsecutiveSkipDefaults() {
        XCTAssertEqual(Config().maxConsecutiveSkips, 2)
        XCTAssertTrue(Config().requireFullRest)
    }

    // max_consecutive_skips 解析
    func testMaxConsecutiveSkipsParsing() {
        XCTAssertEqual(Config.parse("max_consecutive_skips = 5").maxConsecutiveSkips, 5)
        XCTAssertEqual(Config.parse("max_consecutive_skips = 1").maxConsecutiveSkips, 1)
    }

    // 0 = 不限。必须经 parse 验证:README 把 `= 0` 作为老用户恢复旧行为的唯一出口,
    // 若校验范围误写成 (1...100),0 会被当非法值回退成 2,出口失效而无人发现。
    func testMaxConsecutiveSkipsZeroParses() {
        XCTAssertEqual(Config.parse("max_consecutive_skips = 0").maxConsecutiveSkips, 0)
    }

    // 非法/越界回退默认
    func testMaxConsecutiveSkipsInvalidFallsBackToDefault() {
        XCTAssertEqual(Config.parse("max_consecutive_skips = abc").maxConsecutiveSkips, 2)
        XCTAssertEqual(Config.parse("max_consecutive_skips = -1").maxConsecutiveSkips, 2)
        XCTAssertEqual(Config.parse("max_consecutive_skips = 101").maxConsecutiveSkips, 2)
    }

    // 边界值本身合法
    func testMaxConsecutiveSkipsBoundaryAccepted() {
        XCTAssertEqual(Config.parse("max_consecutive_skips = 100").maxConsecutiveSkips, 100)
    }

    // require_full_rest 解析:on/off/非法值回退
    func testRequireFullRestParsing() {
        XCTAssertFalse(Config.parse("require_full_rest = off").requireFullRest)
        XCTAssertTrue(Config.parse("require_full_rest = on").requireFullRest)
        XCTAssertTrue(Config.parse("require_full_rest = maybe").requireFullRest)
        XCTAssertTrue(Config.parse("").requireFullRest)
    }

    // defaultFileContent 里两个新键的键名真的能被 parse 认出。
    // 不能依赖 testDefaultFileContentRoundTrips:新键的文件值(2 / on)恰好等于 Swift 侧默认值,
    // 故漏加行、文件里键名拼错、或 parse 的 case 标签拼错(命中 default: continue),它统统照样绿。
    // 也不能用 defaultFileContent.contains("max_consecutive_skips"):那根本不调 parser。
    // 把文件里的值换成非默认值再 parse,两侧键名任一拼错都会让断言失败。
    func testDefaultFileContentDeclaresNewKeys() {
        let text = Config.defaultFileContent
            .replacingOccurrences(of: "max_consecutive_skips = 2", with: "max_consecutive_skips = 7")
            .replacingOccurrences(of: "require_full_rest = on", with: "require_full_rest = off")
        let c = Config.parse(text)
        XCTAssertEqual(c.maxConsecutiveSkips, 7)   // 文件里键名拼错 → 替换不命中 → 仍为 2 → 失败
        XCTAssertFalse(c.requireFullRest)          // parse 的 case 拼错 → 取不到 off → 仍为 true → 失败
    }
```

- [ ] **Step 2: 确认测试失败(CI)**

本地无 Swift 工具链,严格的「红」需要单独 push 一次。若要走严格 TDD:此时 `git add -A && git commit -m "test(config): consecutive skip limit keys" && git push`,然后:

Run: `GH_CONFIG_DIR=/home/paha/CCWorkspace/cloneWorkToRevise/RestEyes/.gh-config gh run watch`
Expected: `swift test` job **FAIL**,报 `value of type 'Config' has no member 'maxConsecutiveSkips'`。

否则直接进 Step 3,由 Step 5 的绿 run 兜底。

- [ ] **Step 3: 加两个字段**

在 `Sources/RestEyesCore/Config.swift` 的 `public var lockOnUnlock: Bool = true` 之后加:

```swift
    public var maxConsecutiveSkips: Int = 2
    public var requireFullRest: Bool = true
```

- [ ] **Step 4: 加解析 case 与默认文件两行**

在 `parse` 的 `switch key` 里,`case "lock_on_unlock":` 那一段之后、`default:` 之前加:

```swift
            case "max_consecutive_skips":
                if let v = Int(value), (0...100).contains(v) { c.maxConsecutiveSkips = v }
            case "require_full_rest":
                if value == "on" { c.requireFullRest = true }
                else if value == "off" { c.requireFullRest = false }
```

在 `defaultFileContent` 的 `lock_on_unlock = on ...` 那一行之后加两行(注意该字符串以 `"""` 结尾,新行加在结束定界符之前):

```
    max_consecutive_skips = 2   # 连续暂停/跳过几次后必须先完成一次休息;1 = 不允许连续;0 = 不限
    require_full_rest = on      # 必须完整休息完才清零连续计数;off = 中途点「解锁」也算(on/off)
```

- [ ] **Step 5: 确认测试通过(CI)并提交**

Run:
```bash
git add -A && git commit -m "feat(config): add max_consecutive_skips + require_full_rest" && git push
GH_CONFIG_DIR=/home/paha/CCWorkspace/cloneWorkToRevise/RestEyes/.gh-config gh run watch
```
Expected: `swift test` job **GREEN**。7 条新测试通过;既有 `testDefaultFileContentRoundTrips` 仍绿(文件值 `2`/`on` 与默认值一致,往返成立);既有 `testParseEmptyTextGivesDefaults`、`testInvalidValuesFallBackToDefaults`、`testUnknownKeysIgnored` 仍绿。

---

## Task 2: 计数器 + `pause()` 拒绝

**Files:**
- Modify: `Sources/RestEyesCore/BreakScheduler.swift`
- Test: `Tests/RestEyesCoreTests/BreakSchedulerTests.swift`

**Interfaces:**
- Consumes: `Config.maxConsecutiveSkips`(Task 1)
- Produces: `BreakScheduler.consecutiveSkips: Int`(`public private(set)`)、私有计算属性 `skipsExhausted: Bool`、`pause(now:) -> Bool`(`@discardableResult`)。Task 3–6 全部依赖。

- [ ] **Step 1: 扩展测试 helper**

`Tests/RestEyesCoreTests/BreakSchedulerTests.swift` 的 `makeConfig` 增两个带默认值的参数(既有调用点无需改写):

```swift
    private func makeConfig(work: Double = 1, rest: Double = 1, warn: Int = 10,
                            unlock: UnlockAfter = .seconds(60),
                            maxSkips: Int = 2, requireFullRest: Bool = true) -> Config {
        var c = Config()
        c.workMinutes = work      // 1 分钟 = 60 秒,便于推算
        c.restMinutes = rest
        c.warnSeconds = warn
        c.unlockAfter = unlock
        c.maxConsecutiveSkips = maxSkips
        c.requireFullRest = requireFullRest
        return c
    }
```

- [ ] **Step 2: 写失败的测试**

追加到 `BreakSchedulerTests` 类里:

```swift
    // pause 成功:返回 true 且记 1 次
    func testPauseCountsOnce() {
        let (s, _, _) = makeScheduler(makeConfig())
        XCTAssertTrue(s.pause(now: after(10)))
        XCTAssertEqual(s.consecutiveSkips, 1)
    }

    // 达上限:pause 返回 false,相位不变、计数不变
    func testPauseRejectedWhenExhausted() {
        let (s, _, _) = makeScheduler(makeConfig(maxSkips: 2))
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        XCTAssertTrue(s.pause(now: after(30)))
        s.resume(now: after(40))
        XCTAssertEqual(s.consecutiveSkips, 2)
        XCTAssertFalse(s.pause(now: after(50)))
        XCTAssertEqual(s.phase, .working)
        XCTAssertEqual(s.consecutiveSkips, 2)
    }

    // 相位守卫在计数之前:resting 中 pause 被拒且不计数
    // (warning → resting 恰在点击瞬间切换的竞态下,不得记下一次根本没发生的暂停)
    func testPauseInRestingDoesNotCount() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.breakNow(now: t0)
        XCTAssertFalse(s.pause(now: after(10)))
        XCTAssertEqual(s.phase, .resting)
        XCTAssertEqual(s.consecutiveSkips, 0)
    }

    // 提前恢复不退还
    func testResumeDoesNotRefund() {
        let (s, _, _) = makeScheduler(makeConfig())
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(100))
        XCTAssertEqual(s.consecutiveSkips, 1)
    }

    // max_consecutive_skips = 0 → 不限
    func testMaxZeroNeverRejects() {
        let (s, _, _) = makeScheduler(makeConfig(maxSkips: 0))
        for i in 0..<10 {
            XCTAssertTrue(s.pause(now: after(TimeInterval(i * 10))))
            s.resume(now: after(TimeInterval(i * 10 + 5)))
        }
        XCTAssertEqual(s.consecutiveSkips, 10)
    }

    // max_consecutive_skips = 1 → 不允许连续:第二次即被拒
    func testMaxOneRejectsSecond() {
        let (s, _, _) = makeScheduler(makeConfig(maxSkips: 1))
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        XCTAssertFalse(s.pause(now: after(30)))
        XCTAssertEqual(s.consecutiveSkips, 1)
    }
```

- [ ] **Step 3: 加计数器与判定**

在 `Sources/RestEyesCore/BreakScheduler.swift` 的 `public private(set) var config: Config` 之后加:

```swift
    /// 连续暂停/跳过次数;每次真的休息完归零。达 max_consecutive_skips 后暂停与跳过均被拒绝。
    public private(set) var consecutiveSkips = 0
```

在 `// MARK: - 私有` 之下(`startWork` 之前)加:

```swift
    /// 0 = 不限。
    private var skipsExhausted: Bool {
        config.maxConsecutiveSkips > 0 && consecutiveSkips >= config.maxConsecutiveSkips
    }
```

- [ ] **Step 4: `pause()` 改为返回 `Bool` 并内查上限**

把 `pause(now:)` 整个替换为:

```swift
    @discardableResult
    public func pause(now: Date) -> Bool {
        guard phase == .working || phase == .warning else { return false }
        guard !skipsExhausted else { return false }
        consecutiveSkips += 1
        transition(to: .paused, deadline: now.addingTimeInterval(Self.pauseDuration))
        return true
    }
```

相位守卫必须在计数之前:否则竞态下点击落空时会白记一次。

- [ ] **Step 5: 确认测试通过(CI)并提交**

Run:
```bash
git add -A && git commit -m "feat(scheduler): consecutive skip counter; pause() rejects when exhausted" && git push
GH_CONFIG_DIR=/home/paha/CCWorkspace/cloneWorkToRevise/RestEyes/.gh-config gh run watch
```
Expected: `swift test` job **GREEN**。6 条新测试通过。既有 `testPauseIgnoredDuringResting`、`testPauseAutoResumesAfterOneHour`、`testResumeEarlyRestartsWork`、`testReloadWhilePausedKeepsPause`、`testBreakNowFromPausedEntersResting` 仍绿(它们各只暂停一次,`@discardableResult` 让忽略返回值不产生警告)。

---

## Task 3: `endRest` 收口 —— 跑满归零、没跑满 `+1`

**Files:**
- Modify: `Sources/RestEyesCore/BreakScheduler.swift`
- Test: `Tests/RestEyesCoreTests/BreakSchedulerTests.swift`

**Interfaces:**
- Consumes: `Config.requireFullRest`、`Config.restMinutes`、`Config.wakeEndsRest`(Task 1 与既有);`consecutiveSkips`(Task 2)
- Produces: 私有 `endRest(now:reason:restWasFull:)`。Task 4 的 `tick()` 改造依赖它已存在。

**为什么「没跑满」必须 `+1` 而不只是「不清零」**:掐断休息这条路本就不消耗计数,「不清零」对它等于零惩罚——「休息一开始就合盖 6 秒」即成为零成本、不计数、无上限的逃避路径,比点暂停还省事,`max_consecutive_skips` 永不触发。

- [ ] **Step 1: 写失败的测试**

追加到 `BreakSchedulerTests` 类里:

```swift
    // 休息自然走完 → 清零
    func testCompletedRestResetsCount() {
        let (s, _, _) = makeScheduler(makeConfig())
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        XCTAssertEqual(s.consecutiveSkips, 1)
        s.breakNow(now: after(30))
        s.tick(now: after(90))                          // 休息 60 秒走完
        XCTAssertEqual(s.phase, .working)
        XCTAssertEqual(s.consecutiveSkips, 0)
    }

    // unlock 未到点 + require_full_rest = on → +1
    func testUnlockEarlyCountsWhenFullRestRequired() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.breakNow(now: t0)
        s.unlock(now: after(20))                        // rest = 60s,未到点
        XCTAssertEqual(s.consecutiveSkips, 1)
    }

    // unlock 未到点 + require_full_rest = off → 清零
    func testUnlockEarlyResetsWhenFullRestNotRequired() {
        let (s, _, _) = makeScheduler(makeConfig(requireFullRest: false))
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        s.breakNow(now: after(30))
        s.unlock(now: after(40))
        XCTAssertEqual(s.consecutiveSkips, 0)
    }

    // unlock 在 deadline 之后调用(「已到点但本秒 tick 还没跑」的窗口)→ 清零
    func testUnlockAfterDeadlineResets() {
        let (s, _, _) = makeScheduler(makeConfig())
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        XCTAssertEqual(s.consecutiveSkips, 1)
        s.breakNow(now: after(30))                      // 休息 60 秒 → deadline = 90
        s.unlock(now: after(91))
        XCTAssertEqual(s.consecutiveSkips, 0)
    }

    // systemDidWake:休息已到点 → 清零
    func testWakePastRestDeadlineResets() {
        let (s, _, _) = makeScheduler(makeConfig())
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        s.breakNow(now: after(30))                      // deadline = 90
        s.systemDidWake(sleptFor: 5, now: after(95))
        XCTAssertEqual(s.consecutiveSkips, 0)
    }

    // systemDidWake:休息未到点 + 短离开 + require_full_rest = on → +1
    // 这是「休息一开始就合盖 6 秒」那条零成本逃避路径,决策 9 要堵的正是它。
    func testShortWakeDuringRestCountsAsEscape() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.breakNow(now: t0)
        s.systemDidWake(sleptFor: 6, now: after(6))     // rest = 60s 未到点
        XCTAssertEqual(s.phase, .working)
        XCTAssertEqual(s.consecutiveSkips, 1)
    }

    // systemDidWake:休息未到点但离开 >= rest_minutes → 清零
    // 离开可以早于休息开始(离开期间计时不冻结),故会出现「离开很久但休息刚开始」——不该被罚。
    func testLongAwayDuringRestResetsEvenBeforeDeadline() {
        let (s, _, _) = makeScheduler(makeConfig())
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        XCTAssertEqual(s.consecutiveSkips, 1)
        s.breakNow(now: after(30))                      // deadline = 90
        s.systemDidWake(sleptFor: 70, now: after(80))   // 离开 70s >= rest 60s,但 now < deadline
        XCTAssertEqual(s.phase, .working)
        XCTAssertEqual(s.consecutiveSkips, 0)
    }

    // systemDidWake:休息未到点 + wake_ends_rest = off → 休息继续,计数既不清零也不 +1
    func testWakeWithWakeEndsRestOffLeavesCountUntouched() {
        var c = makeConfig()
        c.wakeEndsRest = false
        let (s, _, _) = makeScheduler(c)
        s.breakNow(now: t0)
        s.systemDidWake(sleptFor: 6, now: after(6))
        XCTAssertEqual(s.phase, .resting)
        XCTAssertEqual(s.consecutiveSkips, 0)
    }

    // 连掐 max 次不完整休息后 pause 被拒 —— 钉死决策 9 真的堵住了那条路
    func testRepeatedShortWakesExhaustBudget() {
        let (s, _, _) = makeScheduler(makeConfig(maxSkips: 2))
        s.breakNow(now: t0)
        s.systemDidWake(sleptFor: 6, now: after(6))     // +1
        s.breakNow(now: after(10))
        s.systemDidWake(sleptFor: 6, now: after(16))    // +1
        XCTAssertEqual(s.consecutiveSkips, 2)
        XCTAssertFalse(s.pause(now: after(20)))
    }

    // 工作中长睡 >= rest_minutes → 清零
    func testLongSleepInWorkingResets() {
        let (s, _, _) = makeScheduler(makeConfig())
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        XCTAssertEqual(s.consecutiveSkips, 1)
        s.systemDidWake(sleptFor: 60, now: after(80))   // rest = 60s
        XCTAssertEqual(s.consecutiveSkips, 0)
    }

    // 工作中短睡 → 不清零、不消耗 armed skip
    func testShortSleepInWorkingKeepsCountAndArm() {
        let (s, _, _) = makeScheduler(makeConfig())
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        s.toggleSkipNext()
        s.systemDidWake(sleptFor: 10, now: after(30))
        XCTAssertEqual(s.consecutiveSkips, 1)
        XCTAssertTrue(s.skipNextArmed)
    }

    // .paused 相位长睡 → 清零,且暂停 deadline 不变(清零提到 switch 之前才成立)
    func testLongSleepWhilePausedResetsButKeepsPause() {
        let (s, _, _) = makeScheduler(makeConfig(maxSkips: 2))
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        XCTAssertTrue(s.pause(now: after(30)))          // 计数 = 2,已满;暂停至 3630
        XCTAssertEqual(s.consecutiveSkips, 2)
        s.systemDidWake(sleptFor: 60, now: after(90))
        XCTAssertEqual(s.consecutiveSkips, 0)
        XCTAssertEqual(s.phase, .paused)                // 暂停未被打断、不补偿
        s.tick(now: after(3629))
        XCTAssertEqual(s.phase, .paused)
        s.tick(now: after(3630))
        XCTAssertEqual(s.phase, .working)
    }

    // .paused 相位短睡 → 不清零
    func testShortSleepWhilePausedKeepsCount() {
        let (s, _, _) = makeScheduler(makeConfig())
        XCTAssertTrue(s.pause(now: after(10)))
        s.systemDidWake(sleptFor: 10, now: after(20))
        XCTAssertEqual(s.consecutiveSkips, 1)
        XCTAssertEqual(s.phase, .paused)
    }
```

- [ ] **Step 2: 加 `endRest`**

在 `Sources/RestEyesCore/BreakScheduler.swift` 的 `// MARK: - 私有` 之下、`startWork` 之前加:

```swift
    /// 结束休息:跑满了就清零连续计数;没跑满则算一次逃避 +1(require_full_rest = off 时一律清零)。
    /// startWork 在前、onRestEnded 在后,维持既有回调顺序(见 testRestEndReasonFiresAfterPhaseChange)。
    private func endRest(now: Date, reason: RestEndReason, restWasFull: Bool) {
        if restWasFull || !config.requireFullRest {
            consecutiveSkips = 0
        } else {
            consecutiveSkips += 1        // 没跑满 = 一次逃避,占额度
        }
        startWork(now: now)
        onRestEnded?(reason)
    }
```

- [ ] **Step 3: `tick()` 的 `.resting` 分支改走 `endRest`**

把 `tick(now:)` 里的

```swift
            case .resting:
                startWork(now: now)
                onRestEnded?(.completed)
```

替换为:

```swift
            case .resting:
                endRest(now: now, reason: .completed, restWasFull: true)
```

- [ ] **Step 4: `unlock()` 改走 `endRest`**

把 `unlock(now:)` 整个替换为:

```swift
    public func unlock(now: Date) {
        guard phase == .resting else { return }
        // now >= deadline 只在「已到点但本秒 tick 还没跑」的 ~1 秒窗口内为真,此时休息其实已走完。
        endRest(now: now, reason: .unlocked, restWasFull: now >= deadline)
    }
```

- [ ] **Step 5: 改造 `systemDidWake()`**

把 `systemDidWake(sleptFor:now:)` 整个替换为:

```swift
    public func systemDidWake(sleptFor: TimeInterval, now: Date) {
        // 睡/离开够一次休息时长 = 视为已休息,任何相位一律清零(含 .paused;
        // 必须在 switch 之前,否则暂停中合盖过夜回来计数仍是满的)。
        if sleptFor >= config.restMinutes * 60 { consecutiveSkips = 0 }

        switch phase {
        case .resting:
            if now >= deadline {
                endRest(now: now, reason: .wake, restWasFull: true)
            } else if config.wakeEndsRest {
                // 未到点被掐断:离开/睡眠够一次休息时长也算休息过了,否则记一次逃避。
                // 离开可早于休息开始(离开期间计时不冻结),故 now < deadline 不等于「没休息够」。
                endRest(now: now, reason: .wake, restWasFull: sleptFor >= config.restMinutes * 60)
            }
            // 未到点且 wake_ends_rest = off:遮罩继续,按墙钟走
        case .working, .warning:
            if sleptFor >= config.restMinutes * 60 {
                startWork(now: now)                              // 睡够了,视为已休息
            } else {
                deadline = deadline.addingTimeInterval(sleptFor) // 睡眠期间计时暂停
            }
        case .paused:
            break                                                // 暂停按墙钟,不补偿
        }
    }
```

- [ ] **Step 6: 确认测试通过(CI)并提交**

Run:
```bash
git add -A && git commit -m "feat(scheduler): endRest counts incomplete rests as escapes" && git push
GH_CONFIG_DIR=/home/paha/CCWorkspace/cloneWorkToRevise/RestEyes/.gh-config gh run watch
```
Expected: `swift test` job **GREEN**。13 条新测试通过。既有 `testRestEndReasonCompleted`、`testRestEndReasonUnlocked`、`testRestEndReasonWake`、`testRestEndReasonFiresAfterPhaseChange`、`testRestEndReasonNotFiredWhenWakeKeepsResting`、`testWakeDuringRestPastDeadlineEndsRest`、`testWakeDuringRestBeforeDeadlineKeepsRestingWhenDisabled`、`testWakeDuringRestBeforeDeadlineEndsRestByDefault`、`testWakeShortSleepExtendsWorkDeadline`、`testWakeLongSleepResetsWork`、`testUnlockEndsRestEarly`、`testUnlockIgnoredOutsideResting` 全部仍绿。

---

## Task 4: 跳过的消费点 —— `advancePastWorkDeadline`

**Files:**
- Modify: `Sources/RestEyesCore/BreakScheduler.swift`
- Test: `Tests/RestEyesCoreTests/BreakSchedulerTests.swift`

**Interfaces:**
- Consumes: `skipsExhausted`、`consecutiveSkips`(Task 2);`endRest`(Task 3,`tick` 同一 `switch` 内)
- Produces: 私有 `advancePastWorkDeadline(now:)`

**为什么计数必须在核心**:`tick()` 的 `else if skipNextArmed` 分支是跳过真正吃掉休息的唯一路径,它有两个入口——`working` + armed 时 `startWork` 令相位 `working → working`,`transition()` 判 `phase != newPhase` 不成立,`onPhaseChange` **根本不触发**,胶水层完全观测不到;`warning` + armed 时虽触发 `onPhaseChange(.working)`,但胶水层无法把它与其他回工作的路径可靠区分。两个入口都不足以让胶水层安全记账。

- [ ] **Step 1: 写失败的测试**

追加到 `BreakSchedulerTests` 类里:

```swift
    // working 中 armed + 未满 → 跳过生效,+1
    func testSkipInWorkingCounts() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.toggleSkipNext()
        s.tick(now: after(60))
        XCTAssertEqual(s.phase, .working)
        XCTAssertFalse(s.skipNextArmed)
        XCTAssertEqual(s.consecutiveSkips, 1)
    }

    // warning 中 armed + 未满 → 跳过生效,+1(镜像 testSkipNextDuringWarning)
    func testSkipInWarningCounts() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.tick(now: after(60))
        XCTAssertEqual(s.phase, .warning)
        s.toggleSkipNext()
        s.tick(now: after(70))
        XCTAssertEqual(s.phase, .working)
        XCTAssertEqual(s.consecutiveSkips, 1)
    }

    // working 中 armed + 已满 → 作废勾选、照走预警、不计数
    // 落回正常路径而非直接 startRest:armed 时原逻辑绕过预警,拒绝后直接休息会让用户毫无预警地黑屏。
    func testSkipRefusedWhenExhaustedFallsBackToWarning() {
        let (s, _, _) = makeScheduler(makeConfig(maxSkips: 1))
        XCTAssertTrue(s.pause(now: after(10)))          // 计数 = 1,已满
        s.resume(now: after(20))                        // 工作至 80
        s.toggleSkipNext()
        s.tick(now: after(80))
        XCTAssertEqual(s.phase, .warning)               // 该给的预警照给
        XCTAssertFalse(s.skipNextArmed)                 // 勾选被作废
        XCTAssertEqual(s.consecutiveSkips, 1)           // 不计数
        s.tick(now: after(90))
        XCTAssertEqual(s.phase, .resting)               // 预警走完照常休息
    }

    // warning 中 armed + 已满 → 作废勾选、直接休息、不计数
    func testSkipRefusedInWarningGoesToRest() {
        let (s, _, _) = makeScheduler(makeConfig(maxSkips: 1))
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        s.tick(now: after(80))
        XCTAssertEqual(s.phase, .warning)
        s.toggleSkipNext()
        s.tick(now: after(90))
        XCTAssertEqual(s.phase, .resting)
        XCTAssertFalse(s.skipNextArmed)
        XCTAssertEqual(s.consecutiveSkips, 1)
    }

    // warn_seconds = 0 + armed + 已满 → 直接休息、不计数
    func testSkipRefusedWithZeroWarnGoesToRest() {
        let (s, _, _) = makeScheduler(makeConfig(warn: 0, maxSkips: 1))
        XCTAssertTrue(s.pause(now: after(10)))
        s.resume(now: after(20))
        s.toggleSkipNext()
        s.tick(now: after(80))
        XCTAssertEqual(s.phase, .resting)
        XCTAssertEqual(s.consecutiveSkips, 1)
    }

    // breakNow 清 armed 是丢弃不是消耗 → 不计数
    func testBreakNowDiscardsArmWithoutCounting() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.toggleSkipNext()
        s.breakNow(now: after(10))
        XCTAssertEqual(s.phase, .resting)
        XCTAssertFalse(s.skipNextArmed)
        XCTAssertEqual(s.consecutiveSkips, 0)
    }

    // 反复切换开关不烧计数
    func testTogglingSkipDoesNotCount() {
        let (s, _, _) = makeScheduler(makeConfig())
        for _ in 0..<5 { s.toggleSkipNext(); s.toggleSkipNext() }
        XCTAssertEqual(s.consecutiveSkips, 0)
    }

    // 共用计数池:pause 1 次 + 跳过 1 次 = 2,max = 2 时第三次被拒
    func testPauseAndSkipShareTheSameBudget() {
        let (s, _, _) = makeScheduler(makeConfig(maxSkips: 2))
        XCTAssertTrue(s.pause(now: after(10)))          // 1
        s.resume(now: after(20))
        s.toggleSkipNext()
        s.tick(now: after(80))                          // 跳过生效 → 2
        XCTAssertEqual(s.consecutiveSkips, 2)
        XCTAssertFalse(s.pause(now: after(90)))
    }
```

- [ ] **Step 2: 加 `advancePastWorkDeadline`**

在 `Sources/RestEyesCore/BreakScheduler.swift` 的 `endRest` 之后加:

```swift
    /// 工作/预警到点:决定走「跳过」「预警」还是「休息」。
    /// 跳过只在 armed 且未达上限时生效并 +1;达上限则作废勾选、落回正常路径(该给的预警照给)。
    private func advancePastWorkDeadline(now: Date) {
        if skipNextArmed {
            skipNextArmed = false
            if !skipsExhausted {
                consecutiveSkips += 1
                startWork(now: now)
                return
            }
        }
        if phase == .working, config.warnSeconds > 0 {
            transition(to: .warning, deadline: now.addingTimeInterval(TimeInterval(config.warnSeconds)))
        } else {
            startRest(now: now)
        }
    }
```

- [ ] **Step 3: `tick()` 的工作/预警分支改走它**

把 `tick(now:)` 里的

```swift
            case .working, .warning:
                if phase == .working, config.warnSeconds > 0, !skipNextArmed {
                    transition(to: .warning,
                               deadline: now.addingTimeInterval(TimeInterval(config.warnSeconds)))
                } else if skipNextArmed {
                    skipNextArmed = false
                    startWork(now: now)
                } else {
                    startRest(now: now)
                }
```

替换为:

```swift
            case .working, .warning:
                advancePastWorkDeadline(now: now)
```

原三层嵌套条件(含 `!skipNextArmed` 的反向判断)随之捋直。

- [ ] **Step 4: 确认测试通过(CI)并提交**

Run:
```bash
git add -A && git commit -m "feat(scheduler): count skips at consumption; refuse when exhausted" && git push
GH_CONFIG_DIR=/home/paha/CCWorkspace/cloneWorkToRevise/RestEyes/.gh-config gh run watch
```
Expected: `swift test` job **GREEN**。8 条新测试通过。既有 `testFullCycle`、`testWarnZeroSkipsWarning`、`testSkipNextSkipsOneBreakThenClears`、`testToggleSkipNextTwiceCancels`、`testSkipNextDuringWarning`、`testBreakNowEntersRestingAndClearsSkip` 全部仍绿(默认 `maxSkips = 2`,这些用例各至多消费一次跳过)。

---

## Task 5: `reload()` 堵掉一键免费跳过

**Files:**
- Modify: `Sources/RestEyesCore/BreakScheduler.swift`
- Test: `Tests/RestEyesCoreTests/BreakSchedulerTests.swift`

**Interfaces:**
- Consumes: `Config.workMinutes`(既有)
- Produces: 无新符号,仅收紧 `reload(config:now:)` 的行为

**这是既有代码里的洞,不修则本功能失效**:`reload()` 在 `.working`/`.warning` 相位**无条件** `startWork(now:)`,即便配置一个字节都没变;而「重新加载配置」菜单项从不置灰(`menu.autoenablesItems = false`,`isEnabled` 默认 `true` 从未被改写)。于是在 `.warning` 相位(黑屏还有 10 秒)点一下它 → 休息被取消、白得一整个 `work_minutes`、计数不变——比点暂停还省事,且完全不计数。

- [ ] **Step 1: 写失败的测试**

追加到 `BreakSchedulerTests` 类里:

```swift
    // reload 只改 message → deadline 不变(堵「预警中点重新加载配置 = 免费跳过」)
    func testReloadWithoutDurationChangeKeepsDeadline() {
        let (s, _, _) = makeScheduler(makeConfig(work: 1))
        var c = makeConfig(work: 1)
        c.message = "新文案"
        s.reload(config: c, now: after(30))
        XCTAssertEqual(s.config.message, "新文案")
        s.tick(now: after(60))
        XCTAssertEqual(s.phase, .warning)               // 原 deadline 未被重置
    }

    // .warning 中 reload → 相位仍是 warning,预警到点照常进 resting
    func testReloadDuringWarningKeepsWarning() {
        let (s, _, _) = makeScheduler(makeConfig())
        s.tick(now: after(60))
        XCTAssertEqual(s.phase, .warning)
        var c = makeConfig(work: 5)
        c.message = "改了"
        s.reload(config: c, now: after(65))
        XCTAssertEqual(s.phase, .warning)               // 不被取消
        s.tick(now: after(70))
        XCTAssertEqual(s.phase, .resting)               // 预警走完照常休息
    }

    // reload 不清零计数
    func testReloadKeepsCount() {
        let (s, _, _) = makeScheduler(makeConfig())
        XCTAssertTrue(s.pause(now: after(10)))
        s.reload(config: makeConfig(work: 2), now: after(20))
        XCTAssertEqual(s.consecutiveSkips, 1)
    }
```

- [ ] **Step 2: 收紧 `reload()`**

把 `reload(config:now:)` 整个替换为:

```swift
    public func reload(config: Config, now: Date) {
        let previous = self.config
        self.config = config
        if phase == .working, config.workMinutes != previous.workMinutes {
            startWork(now: now)          // 只在工作时长真的变了时才按新时长重开
        }
        // warning/resting/paused:当前 deadline 不动,新配置自下个周期生效
    }
```

副带收益:改 `message` 之类与时长无关的配置不再重置工作倒计时——`reloadConfigIfChanged` 每个工作周期开头都会跑,原先任何配置变动都会白送一次计时重开。

- [ ] **Step 3: 确认测试通过(CI)并提交**

Run:
```bash
git add -A && git commit -m "fix(scheduler): reload no longer grants a free skip" && git push
GH_CONFIG_DIR=/home/paha/CCWorkspace/cloneWorkToRevise/RestEyes/.gh-config gh run watch
```
Expected: `swift test` job **GREEN**。3 条新测试通过。既有三条 reload 用例仍绿:`testReloadDuringWorkingRestartsWithNewDuration`(work `1→2`,`.working` 相位 → `workMinutes` 不同 → 仍重开)、`testReloadDuringRestingKeepsRestDeadline`、`testReloadWhilePausedKeepsPause`。

---

## Task 6: `TickInfo` 字段 + 菜单置灰 + 胶水层接线

**Files:**
- Modify: `Sources/RestEyesCore/BreakScheduler.swift`(`TickInfo` + `tickInfo`)
- Modify: `Sources/RestEyes/StatusItem.swift`
- Modify: `Sources/RestEyes/main.swift`
- Test: `Tests/RestEyesCoreTests/BreakSchedulerTests.swift`

**Interfaces:**
- Consumes: `skipsExhausted`(Task 2)
- Produces: `TickInfo.skipsExhausted: Bool`(**无默认值**);`StatusItemController.update(phase:remaining:skipNextArmed:skipsExhausted:)`

- [ ] **Step 1: 写失败的测试**

追加到 `BreakSchedulerTests` 类里:

```swift
    // TickInfo 上报禁用状态
    func testTickInfoReportsSkipsExhausted() {
        let (s, _, infos) = makeScheduler(makeConfig(maxSkips: 1))
        s.tick(now: after(1))
        XCTAssertFalse(infos().last!.skipsExhausted)
        XCTAssertTrue(s.pause(now: after(2)))
        s.tick(now: after(3))
        XCTAssertTrue(infos().last!.skipsExhausted)
    }
```

- [ ] **Step 2: `TickInfo` 加字段**

把 `TickInfo` 整个替换为:

```swift
public struct TickInfo: Equatable {
    public var phase: Phase
    public var remaining: TimeInterval
    public var unlockVisible: Bool
    public var skipsExhausted: Bool      // true = 已达连续上限,暂停与跳过均不可用
}
```

**不给默认值**:全仓 `TickInfo(` 只有一个构造点(`tickInfo(now:)`,下一步就改)。默认值不带来任何兼容收益,只会让将来漏填的构造点静默取到 `false`(= 放行),失去编译期保护。

- [ ] **Step 3: `tickInfo(now:)` 填该字段**

把 `tickInfo(now:)` 整个替换为:

```swift
    private func tickInfo(now: Date) -> TickInfo {
        TickInfo(phase: phase,
                 remaining: max(0, deadline.timeIntervalSince(now)),
                 unlockVisible: unlockVisible(now: now),
                 skipsExhausted: skipsExhausted)
    }
```

- [ ] **Step 4: 菜单置灰与标题**

把 `Sources/RestEyes/StatusItem.swift` 的 `update(phase:remaining:skipNextArmed:)` 整个替换为:

```swift
    func update(phase: Phase, remaining: TimeInterval, skipNextArmed: Bool,
                skipsExhausted: Bool) {
        switch phase {
        case .working:
            countdownItem.title = "距下次休息 \(Format.mmss(remaining))"
        case .warning:
            countdownItem.title = "即将休息…"
        case .resting:
            countdownItem.title = "休息中 \(Format.mmss(remaining))"
        case .paused:
            countdownItem.title = "已暂停(\(Format.mmss(remaining)) 后恢复)"
        }

        // suffix 只在计数是真实致灰原因时才挂:resting 中置灰的原因是「休息中」,与计数无关,
        // 此时说「请先完成一次休息」会误导(它马上就要休息完了)。
        let suffix = (skipsExhausted && phase != .resting) ? "(已达连续上限,请先完成一次休息)" : ""

        if phase == .paused {
            pauseItem.title = "恢复计时"
            pauseItem.isEnabled = true          // 恢复永不被计数禁用,否则会被锁死在暂停里
        } else {
            pauseItem.title = "暂停 1 小时\(suffix)"
            pauseItem.isEnabled = phase != .resting && !skipsExhausted
        }

        skipItem.state = skipNextArmed ? .on : .off
        skipItem.title = "跳过下次休息\(suffix)"
        // armed 时保持可点,否则用户无法取消一个已经不会生效的勾选
        skipItem.isEnabled = phase != .resting && (!skipsExhausted || skipNextArmed)
    }
```

- [ ] **Step 5: 胶水层接线(两处)**

其一,`Sources/RestEyes/main.swift` 的 `scheduler.onTick` 闭包里,把

```swift
            statusItem.update(phase: info.phase, remaining: info.remaining,
                              skipNextArmed: scheduler.skipNextArmed)
```

替换为:

```swift
            statusItem.update(phase: info.phase, remaining: info.remaining,
                              skipNextArmed: scheduler.skipNextArmed,
                              skipsExhausted: info.skipsExhausted)
```

其二,`reconcileIfBack()` 里把

```swift
        case .paused:
            break
```

替换为:

```swift
        case .paused:
            // 仅为「离开够久 → 清零连续计数」;systemDidWake 的 .paused 分支不动暂停 deadline。
            scheduler.systemDidWake(sleptFor: awayFor, now: now)
```

`onPauseToggle` 闭包**不改**:`pause()` 内部判定,达上限即返回 `false` 静默拒绝。置灰是 UI 防线,核心里的 `guard` 才是真防线。

- [ ] **Step 6: 确认 build + 测试通过(CI)并提交**

Run:
```bash
git add -A && git commit -m "feat(ui): grey out pause/skip at consecutive limit" && git push
GH_CONFIG_DIR=/home/paha/CCWorkspace/cloneWorkToRevise/RestEyes/.gh-config gh run watch
```
Expected: `swift test` **GREEN**(新增 1 条;既有 `testTickReportsRemaining`、`testUnlockVisibilityDelayed`、`testUnlockVisibilityNever`、`testUnlockVisibilityImmediate` 仍绿)且 **build job GREEN**(`StatusItem.swift` 与 `main.swift` 编译通过、无未使用变量告警)。

**手动验收**(需 macOS 真机,下载 CI artifact 或 Release):
- 暂停 → 恢复计时 → 暂停 → 恢复计时 → 第三次点「暂停 1 小时」→ 置灰且标题带「(已达连续上限,请先完成一次休息)」
- 用掉最后一次计数进入暂停后,「恢复计时」**仍可点**
- 休息中观察:两项虽置灰,标题**不带**该后缀

---

## Task 7: README + 版本号

**Files:**
- Modify: `README.md`
- Modify: `Resources/Info.plist`

**Interfaces:**
- Consumes: 全部前序任务
- Produces: 无

- [ ] **Step 1: 配置表加两行**

在 `README.md` 的「## 配置」表格里,`lock_on_unlock` 那一行之后加:

```markdown
| `max_consecutive_skips` | `2` | 连续暂停/跳过几次后必须先完成一次休息;`1` = 不允许连续;`0` = 不限 |
| `require_full_rest` | `on` | 必须完整休息完才清零连续计数;`off` = 中途点「解锁」或被唤醒掐断也算休息过 |
```

- [ ] **Step 2: 「已知边界」加四条**

在 `README.md` 的「## 已知边界」小节末尾加:

```markdown
- **升级后默认即被限制**:`max_consecutive_skips` 默认 `2`,而已存在的 `config.txt` 不会被重写(新键缺失即取默认值)。连续暂停/跳过两次后,必须完整休息一次才能再用。想恢复旧的无限次行为,在配置文件里加 `max_consecutive_skips = 0`。
- **`require_full_rest` 默认 `on`**:休息中点「解锁」或 ESC×10 提前逃掉,不但不清零计数,反而算一次逃避(`+1`)。ESC×10 仍永不被拒绝,只是要花额度。
- **计数只在内存里**:退出并重开 RestEyes 即清零。本限制的定位是防手滑、防惯性,不是防自己作弊。
- **不限制总量**:「暂停 1 小时 → 完整休息 → 再暂停 1 小时」可以无限重复。既然每次之间都真的休息了,护眼目的已达成。
- **休息被系统熄屏/屏保打断也可能计一次**:`wake_ends_rest = on`(默认)下,休息未跑满时被打断且离开时长小于 `rest_minutes`,回来会 `+1`。默认熄屏延时远大于默认 `rest_minutes`(3 分钟),实践中罕见;介意可配 `wake_ends_rest = off` 或 `require_full_rest = off`。
```

- [ ] **Step 3: 手动验收清单加条目**

在 `README.md` 的「## 手动验收清单」小节末尾加:

```markdown
- 暂停 → 恢复计时 → 暂停 → 恢复计时 → 第三次点「暂停 1 小时」→ 菜单项置灰,标题显示「(已达连续上限,请先完成一次休息)」。(默认 `max_consecutive_skips = 2`;计数不看时钟,无需卡时间连点。)
- 承上,让一次休息**完整走完** → 两项菜单立即恢复可点。
- 承上,休息中点「解锁」提前结束(默认 `require_full_rest = on`)→ 两项**仍然置灰**;配 `require_full_rest = off` 后同样操作 → 恢复可点。
- 用掉最后一次计数进入暂停后,「恢复计时」**仍可点**(不会被锁死在暂停里)。
- 勾选「跳过下次休息」后用暂停耗尽计数 → 工作到点时**照常预警并休息**,勾选被清除,计数不再增加。
- 勾选状态下达上限 → 菜单项**仍可点**以取消勾选。
- 休息中观察:两项虽置灰,标题**不带**「已达连续上限」后缀。
- 计数满时点暂停 → 合盖过夜 → 回来 → 计数已清零,两项可点。
- 休息刚开始就合盖几秒再打开(默认 `wake_ends_rest = on`)→ 休息结束回到工作,但计数 `+1`;重复到上限后暂停与跳过双双置灰。
- 休息中或预警中点「重新加载配置」→ 休息/预警**不被取消**。
```

- [ ] **Step 4: 版本号**

在 `Resources/Info.plist` 里:`CFBundleShortVersionString` `0.1.11` → `0.1.12`;`CFBundleVersion` `12` → `13`。

- [ ] **Step 5: 提交并确认 CI 绿**

Run:
```bash
git add -A && git commit -m "docs: README + bump 0.1.12 (consecutive pause/skip limit)" && git push
GH_CONFIG_DIR=/home/paha/CCWorkspace/cloneWorkToRevise/RestEyes/.gh-config gh run watch
```
Expected: CI **GREEN**(test + build)。

- [ ] **Step 6: 发布(仅在用户确认真机验收通过后)**

⚠️ **不要自动执行**。v0.1.11 的教训是 tag 才触发 Release(`build.yml` 的 `if: startsWith(github.ref, 'refs/tags/v')`),而 `gh release create` 非幂等——重跑 tag run 会失败。等用户真机验收通过后:

```bash
git tag -a v0.1.12 -m "RestEyes v0.1.12：限制连续暂停/跳过" && git push origin v0.1.12
GH_CONFIG_DIR=/home/paha/CCWorkspace/cloneWorkToRevise/RestEyes/.gh-config gh run watch
GH_CONFIG_DIR=/home/paha/CCWorkspace/cloneWorkToRevise/RestEyes/.gh-config gh release view v0.1.12
```
