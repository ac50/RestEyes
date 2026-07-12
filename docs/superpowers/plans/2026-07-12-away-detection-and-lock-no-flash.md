# 离开检测增强 + 休息结束锁屏不闪桌面 · 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让「休息自然结束→锁屏」时黑遮罩直接切到锁屏界面不露桌面(需求 2);让长时间锁屏/熄屏/合盖后回来一律进入工作、不卡在休息(需求 1)。

**Architecture:** 两处改动全部落在 AppKit 胶水层——`OverlayController`(遮罩两段式撤除)与 `main.swift` 的 `AppDelegate`(休息结束回调分流 + 延迟锁屏撤窗;缺席检测拓宽通知 + 结束轮询兜底)。纯逻辑状态机 `BreakScheduler` 及所有配置**一律不动**,因此现有单元测试全部照旧通过。

**Tech Stack:** Swift 5.10、AppKit、SwiftPM(零第三方依赖);CoreGraphics(`CGDisplayIsAsleep` / `CGSessionCopyCurrentDictionary`);ServiceManagement(既有,不动)。

**Spec:** [../specs/2026-07-12-away-detection-and-lock-no-flash-design.md](../specs/2026-07-12-away-detection-and-lock-no-flash-design.md)

## Global Constraints

- 平台:macOS 26+、Apple Silicon(arm64)。
- **`Sources/RestEyesCore/`(`BreakScheduler` / `Config` / `Format`)一律不改**;不新增、不改名、不改默认任何配置项。
- **不引入第三方依赖**;不申请任何 TCC 权限。
- 本机无 Swift 工具链:**只能通过 `git push` 触发 GitHub Actions(`macos-26`)编译与测试**,任何「编译成功/测试通过」结论以 CI run 为准。
- 所有 `gh` 命令加前缀 `GH_CONFIG_DIR=.gh-config`(在仓库根目录执行);`git push` 无需前缀。
- commit message 结尾统一附:`Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`。

## 验证约定(零上下文工程师必读)

本计划的改动**全在 AppKit 可执行 target(`RestEyes`),不在被测的 `RestEyesCore` 库**,且不改状态机逻辑。因此:

- **不新增单元测试**。窗口撤除时序、系统通知、锁屏、显示器睡眠均依赖真实 GUI/系统环境,无法有意义地单测——这与 spec「测试与验证」一致。
- **每个代码任务的自动验证 = CI 绿**:`swift test` 仍 `Executed 52 tests, with 0 failures`(Config 20 + Scheduler 31 + Format 1,数量不变即证明无回归),且 `swift build -c release --arch arm64` 通过。
- **行为验证 = 真机手动验收**,由用户在 macOS 上跑 CI 产出的 `RestEyes.app` 完成(Linux 开发机无法运行)。各任务列出「真机验收」动作与预期;**任务的完成判据是 CI 绿**,真机验收作为用户侧确认,不阻塞任务推进。

**CI 操作命令**(在仓库根目录):

```bash
git push                                              # 触发 CI(push 即触发)
GH_CONFIG_DIR=.gh-config gh run watch                 # 盯当前最新 run 直到结束
GH_CONFIG_DIR=.gh-config gh run view --log-failed     # 失败时看失败步骤日志
```

预期成功日志含 `Executed 52 tests, with 0 failures`。网络偶发 TLS handshake timeout,重试即可。

---

### Task 1:OverlayController — `hideRest()` 拆为两段(行为不变的重构)

**Files:**
- Modify: `Sources/RestEyes/OverlayController.swift`(`hideRest()` 方法,约 127-145 行)

**Interfaces:**
- Consumes: 无(纯内部重构)
- Produces:
  - `func detachRestInteraction()` —— 停掉遮罩交互(抢焦点定时器、吞键监听、屏幕参数监听)并恢复 `presentationOptions`,**保留黑窗在屏、`isShieldActive` 仍为 true**。幂等。
  - `func removeRestWindows()` —— `orderOut` 全部黑窗、清空数组、置 `isShieldActive = false`。幂等。
  - `func hideRest()` —— 语义不变:`guard isShieldActive` 后依次调用上面两个方法。

**目的:** 把「一步撤除」拆成「停交互」与「撤黑窗」两步,让 Task 2 能在锁屏前停交互、锁屏界面盖上后再撤黑窗。本任务不改变任何调用点,行为等价。

- [ ] **Step 1: 用两段式重写 `hideRest()`**

`Sources/RestEyes/OverlayController.swift` 中,将现有整段:

```swift
    func hideRest() {
        guard isShieldActive else { return }
        isShieldActive = false
        activationTimer?.invalidate()
        activationTimer = nil
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        for window in restWindows { window.orderOut(nil) }
        restWindows = []
        countdownLabels = []
        unlockButtons = []
        NSApp.presentationOptions = savedPresentationOptions
    }
```

替换为:

```swift
    func hideRest() {
        guard isShieldActive else { return }
        detachRestInteraction()
        removeRestWindows()
    }

    /// 停掉遮罩交互(每秒抢焦点定时器、吞键监听、屏幕参数监听)并恢复 presentationOptions,
    /// 但保留黑窗在屏、isShieldActive 仍为 true。用于「休息结束→锁屏」:先停交互(让用户能
    /// 在锁屏界面输入密码),黑窗留到锁屏界面盖上后再由 removeRestWindows() 撤除。幂等。
    func detachRestInteraction() {
        activationTimer?.invalidate()
        activationTimer = nil
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        NSApp.presentationOptions = savedPresentationOptions
    }

    /// 撤掉全部黑窗并复位遮罩状态。幂等(空数组时为 no-op)。
    func removeRestWindows() {
        for window in restWindows { window.orderOut(nil) }
        restWindows = []
        countdownLabels = []
        unlockButtons = []
        isShieldActive = false
    }
```

说明:原实现在开头即置 `isShieldActive = false`,现移到 `removeRestWindows()` 末尾。对 `hideRest()` 而言两步同步执行、无可观察差异;而延迟锁屏路(Task 2)需要 `detachRestInteraction()` 后 `isShieldActive` 仍为 true,以阻止 `showRest()` 的 `guard !isShieldActive` 期间重复弹遮罩。

- [ ] **Step 2: 推送并验证 CI 绿**

```bash
git add Sources/RestEyes/OverlayController.swift
git commit -m "refactor: split OverlayController.hideRest into detach + remove

No behavior change: hideRest() now calls detachRestInteraction() then
removeRestWindows() in sequence. Prepares two-phase teardown so a
post-rest lock can keep the black shield up until the lock screen covers it.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push
GH_CONFIG_DIR=.gh-config gh run watch
```

预期:CI 绿,`Executed 52 tests, with 0 failures`(纯重构,测试数不变)。

---

### Task 2:需求 2 — 休息结束撤窗迁移到 onRestEnded + 延迟锁屏

**Files:**
- Modify: `Sources/RestEyes/main.swift`(`AppDelegate`:新增两个实例属性 + 一个常量;`wire()` 的 `onPhaseChange`/`onRestEnded`;`observeSleepAndLock()` 的 `screenIsLocked` 观察者;新增两个私有方法)

**Interfaces:**
- Consumes: Task 1 的 `overlay.detachRestInteraction()` / `overlay.removeRestWindows()`;既有 `ScreenLocker.lock()`
- Produces: `pendingRestWindowRemoval: Bool`、`finishPendingRestWindowRemoval()`(供 `screenIsLocked` 观察者与兜底计时器调用)

**行为(与 spec 需求 2 一致):** 撤休息遮罩的职责从 `onPhaseChange(.working)` 迁到 `onRestEnded`(退出 resting 必经此回调)。`completed` 且 `lock_after_rest=on` 时,先停交互、黑窗保留、锁屏,待 `com.apple.screenIsLocked` 到达(锁屏界面已盖上)再撤黑窗;2.5 秒兜底防滞留。其余情况立即 `hideRest()`。

- [ ] **Step 1: `onPhaseChange(.working)` 去掉撤遮罩**

`wire()` 中 `scheduler.onPhaseChange` 的 `case .working:`,把:

```swift
            case .working:
                overlay.hideWarning()
                overlay.hideRest()
                reloadConfigIfChanged()      // 每个工作周期开始自动重读配置
```

改为(删掉 `overlay.hideRest()` 一行):

```swift
            case .working:
                overlay.hideWarning()
                // 撤休息遮罩改由 onRestEnded 统一收口(见下),以支持「锁屏前不撤窗」。
                reloadConfigIfChanged()      // 每个工作周期开始自动重读配置
```

- [ ] **Step 2: `onRestEnded` 分流**

`wire()` 中,把现有整段:

```swift
        scheduler.onRestEnded = { [weak self] reason in
            guard let self else { return }
            if reason == .completed, self.scheduler.config.lockAfterRest {
                ScreenLocker.lock()
            }
        }
```

替换为:

```swift
        // 退出 resting 只有 completed/unlocked/wake 三条路,每条都经此回调,故这里是撤遮罩的唯一收口。
        scheduler.onRestEnded = { [weak self] reason in
            guard let self else { return }
            if reason == .completed, self.scheduler.config.lockAfterRest {
                // 休息自然结束且要锁屏:先停交互(让用户能输密码),黑窗保留;
                // 锁屏后等 screenIsLocked(锁屏界面盖上)再撤黑窗,避免中途露出桌面。
                self.overlay.detachRestInteraction()
                ScreenLocker.lock()
                self.pendingRestWindowRemoval = true
                self.startLockConfirmFallback()
            } else {
                self.overlay.hideRest()
            }
        }
```

- [ ] **Step 3: 新增实例属性与常量**

`AppDelegate` 顶部,在 `private var isScreenLocked = false` 之后添加:

```swift
    /// 休息自然结束触发的锁屏尚未撤除黑窗时为 true(等 screenIsLocked 或兜底超时后撤)。
    private var pendingRestWindowRemoval = false
    private var lockConfirmFallbackTimer: Timer?
```

在 `absenceForceClearCeiling` 常量之后添加:

```swift
    /// 锁屏后等待锁屏界面盖上的兜底上限:超时仍未收到 screenIsLocked 就直接撤黑窗,防滞留。
    private static let lockConfirmFallback: TimeInterval = 2.5
```

- [ ] **Step 4: 新增撤窗收口方法**

`AppDelegate` 内(建议放在 `endAbsenceIfPresent()` 附近)添加:

```swift
    private func startLockConfirmFallback() {
        lockConfirmFallbackTimer?.invalidate()
        let timer = Timer(timeInterval: Self.lockConfirmFallback, repeats: false) { [weak self] _ in
            self?.finishPendingRestWindowRemoval()
        }
        RunLoop.main.add(timer, forMode: .common)
        lockConfirmFallbackTimer = timer
    }

    /// 撤除延迟锁屏路保留的黑窗。由 screenIsLocked 观察者(正常)或兜底计时器(降级)调用,幂等。
    private func finishPendingRestWindowRemoval() {
        guard pendingRestWindowRemoval else { return }
        pendingRestWindowRemoval = false
        lockConfirmFallbackTimer?.invalidate()
        lockConfirmFallbackTimer = nil
        overlay.removeRestWindows()
    }
```

- [ ] **Step 5: `screenIsLocked` 观察者触发撤窗**

`observeSleepAndLock()` 中 `com.apple.screenIsLocked` 观察者,把:

```swift
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                        object: nil, queue: .main) { [weak self] _ in
            self?.isScreenLocked = true
            self?.noteAbsenceBegan()
        }
```

改为:

```swift
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                        object: nil, queue: .main) { [weak self] _ in
            self?.isScreenLocked = true
            self?.noteAbsenceBegan()
            self?.finishPendingRestWindowRemoval()   // 锁屏界面已盖上 → 撤掉延迟保留的黑窗
        }
```

- [ ] **Step 6: 推送并验证 CI 绿**

```bash
git add Sources/RestEyes/main.swift
git commit -m "feat: lock-after-rest keeps shield up until lock screen covers it

Rest-shield teardown moves from onPhaseChange(.working) to onRestEnded
(the sole exit path from resting). On natural completion with
lock_after_rest on, detach shield interaction, lock, and remove the
black windows only after com.apple.screenIsLocked arrives (2.5s fallback),
so the desktop never flashes between shield and lock screen.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push
GH_CONFIG_DIR=.gh-config gh run watch
```

预期:CI 绿,`Executed 52 tests, with 0 failures`。

- [ ] **Step 7: 真机验收(用户在 macOS 跑 CI 产物,不阻塞任务完成)**

- `lock_after_rest = on`:等一次休息**自然走完** → 观察从黑遮罩**直接切到系统锁屏界面,中途不露出桌面/工作内容**。
- `lock_after_rest = off`:休息自然结束 → 正常撤遮罩露出桌面、**不锁屏**。
- 休息中点「解锁」按钮或 ESC×10 → 立即撤遮罩、不锁屏(回归)。

---

### Task 3:需求 1 · 缺席开始拓宽通知 + 四标记聚合 + `endAbsence` 收口

**Files:**
- Modify: `Sources/RestEyes/main.swift`(`AppDelegate`:新增两个标记;`observeSleepAndLock()` 加两对观察者;`endAbsenceIfPresent()` 守卫扩展并新增 `endAbsence(awayFor:)`;`startTicking()` 看门狗改用 `endAbsence`)

**Interfaces:**
- Consumes: 既有 `noteAbsenceBegan()` / `scheduler.systemDidWake(sleptFor:now:)`
- Produces: `isDisplayAsleep` / `isScreensaverActive` 标记;`endAbsence(awayFor:)`(Task 4 复用)

**行为(与 spec 需求 1 · 方案 A + 标记聚合 一致):** 缺席触发从「睡眠 + 锁屏」扩到「+ 显示器熄屏 + 屏保」,四者汇入同一套缺席计时;`endAbsenceIfPresent` 需四标记全假才结束;看门狗与(下个任务的)轮询兜底共用 `endAbsence(awayFor:)` 收口。**不改 `BreakScheduler.systemDidWake` 判定,门槛仍是 `rest_minutes`。**

- [ ] **Step 1: 新增两个缺席标记**

`AppDelegate` 顶部,把:

```swift
    private var isAsleep = false
    private var isScreenLocked = false
```

改为:

```swift
    private var isAsleep = false
    private var isScreenLocked = false
    private var isDisplayAsleep = false        // 显示器熄屏(补「纯熄屏无通知」缺口)
    private var isScreensaverActive = false    // 屏保运行中
```

- [ ] **Step 2: 显示器熄屏/亮屏观察者**

`observeSleepAndLock()` 中,在 `didWakeNotification` 观察者块**之后**、`let dnc = ...` 之前,插入:

```swift
        wnc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                        object: nil, queue: .main) { [weak self] _ in
            self?.isDisplayAsleep = true
            self?.noteAbsenceBegan()
        }
        wnc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                        object: nil, queue: .main) { [weak self] _ in
            self?.isDisplayAsleep = false
            self?.endAbsenceIfPresent()
        }
```

- [ ] **Step 3: 屏保启停观察者**

同一方法中,在 `com.apple.screenIsUnlocked` 观察者块**之后**(方法结尾 `}` 之前)插入:

```swift
        dnc.addObserver(forName: Notification.Name("com.apple.screensaver.didstart"),
                        object: nil, queue: .main) { [weak self] _ in
            self?.isScreensaverActive = true
            self?.noteAbsenceBegan()
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screensaver.didstop"),
                        object: nil, queue: .main) { [weak self] _ in
            self?.isScreensaverActive = false
            self?.endAbsenceIfPresent()
        }
```

- [ ] **Step 4: 扩展守卫并新增 `endAbsence(awayFor:)`**

把现有:

```swift
    private func endAbsenceIfPresent() {
        guard !isAsleep, !isScreenLocked, let began = absenceBeganAt else { return }
        absenceBeganAt = nil
        scheduler.systemDidWake(sleptFor: Date().timeIntervalSince(began), now: Date())
    }
```

替换为:

```swift
    private func endAbsenceIfPresent() {
        guard !isAsleep, !isScreenLocked, !isDisplayAsleep, !isScreensaverActive,
              let began = absenceBeganAt else { return }
        endAbsence(awayFor: Date().timeIntervalSince(began))
    }

    /// 强制结束缺席:复位全部缺席标记并按给定离开时长对账。
    /// 看门狗与轮询兜底(Task 4)共用此收口。
    private func endAbsence(awayFor: TimeInterval) {
        isAsleep = false
        isScreenLocked = false
        isDisplayAsleep = false
        isScreensaverActive = false
        absenceBeganAt = nil
        scheduler.systemDidWake(sleptFor: awayFor, now: Date())
    }
```

- [ ] **Step 5: 看门狗改用 `endAbsence`**

`startTicking()` 中,把:

```swift
            if let began = self.absenceBeganAt {
                if Date().timeIntervalSince(began) >= Self.absenceForceClearCeiling {
                    self.isAsleep = false
                    self.isScreenLocked = false
                    self.endAbsenceIfPresent()
                }
                return
            }
```

改为:

```swift
            if let began = self.absenceBeganAt {
                if Date().timeIntervalSince(began) >= Self.absenceForceClearCeiling {
                    self.endAbsence(awayFor: Date().timeIntervalSince(began))
                }
                return
            }
```

- [ ] **Step 6: 推送并验证 CI 绿**

```bash
git add Sources/RestEyes/main.swift
git commit -m "feat: treat display sleep and screensaver as absence

Adds screensDidSleep/Wake and com.apple.screensaver.didstart/didstop to
the absence tracking so a plain display-off or screensaver (no lock) also
freezes the timer. Absence now aggregates four flags; endAbsence(awayFor:)
is the shared force-end used by the watchdog. systemDidWake logic and the
rest_minutes threshold are unchanged.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push
GH_CONFIG_DIR=.gh-config gh run watch
```

预期:CI 绿,`Executed 52 tests, with 0 failures`。

- [ ] **Step 7: 真机验收(不阻塞任务完成)**

- 工作中让显示器**熄屏** ≥ `rest_minutes`(可临时把 `rest_minutes` 调小、能耗设置里把「关闭显示器」设短)再唤醒 → 回到**全新工作**(状态栏「距下次休息」为满值)。
- 熄屏 < `rest_minutes` 再唤醒 → 接着原工作(计时大致从离开处续上)。

---

### Task 4:需求 1 · 缺席结束轮询兜底

**Files:**
- Modify: `Sources/RestEyes/main.swift`(顶部加 `import CoreGraphics`;新增去抖常量与两个私有方法;`startTicking()` 冻结分支加轮询条件)

**Interfaces:**
- Consumes: Task 3 的 `endAbsence(awayFor:)`;CoreGraphics `CGDisplayIsAsleep` / `CGMainDisplayID` / `CGSessionCopyCurrentDictionary`
- Produces: `userIsPresent()`(冻结分支使用)

**行为(与 spec 需求 1 · 方案 B 一致):** 仅在**已缺席(已冻结)**时,主心跳每秒顺带查真实状态——离开 ≥ 去抖阈值(3s)且「屏幕未锁且显示器未睡」即判定用户已回来,立即用 `endAbsence` 对账,**哪怕唤醒/解锁通知漏收**(合盖卡休息的根因)。正常工作期不轮询、零开销。锁屏态默认读 `CGSession` 键(spec 中唯一待复核取舍点;若定为「零私有依赖」,改用 `CGEventSourceSecondsSinceLastEventType` 空闲时间,替换 `screenIsLockedNow()` 实现即可)。

- [ ] **Step 1: 引入 CoreGraphics**

`main.swift` 顶部,把:

```swift
import AppKit
import RestEyesCore
```

改为:

```swift
import AppKit
import CoreGraphics
import RestEyesCore
```

- [ ] **Step 2: 去抖常量**

`AppDelegate` 中,在 `lockConfirmFallback` 常量之后添加:

```swift
    /// 缺席结束轮询去抖:离开不足此秒数不触发轮询解冻,避免刚锁屏那一瞬会话态未落定被误判为「在场」。
    private static let absencePollDebounce: TimeInterval = 3
```

- [ ] **Step 3: 在场判定方法**

`AppDelegate` 内(建议放在 `endAbsence(awayFor:)` 附近)添加:

```swift
    /// 缺席期间轮询:用户是否已回到(屏幕未锁 且 显示器未睡)。
    private func userIsPresent() -> Bool {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return false }   // 显示器在睡 → 仍不在
        if screenIsLockedNow() { return false }                        // 屏幕锁定中 → 仍不在
        return true
    }

    /// 读当前会话锁屏态(CGSSessionScreenIsLocked)。读不到时保守返回 false,
    /// 由 userIsPresent 结合显示器态共同判定。
    private func screenIsLockedNow() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = dict["CGSSessionScreenIsLocked"] as? Bool { return locked }
        if let n = dict["CGSSessionScreenIsLocked"] as? NSNumber { return n.boolValue }
        return false
    }
```

- [ ] **Step 4: 冻结分支加轮询解冻**

`startTicking()` 中,把 Task 3 得到的:

```swift
            if let began = self.absenceBeganAt {
                if Date().timeIntervalSince(began) >= Self.absenceForceClearCeiling {
                    self.endAbsence(awayFor: Date().timeIntervalSince(began))
                }
                return
            }
```

改为:

```swift
            if let began = self.absenceBeganAt {
                let awayFor = Date().timeIntervalSince(began)
                // 看门狗上限,或「离开够久 + 已在场」→ 结束缺席(后者补唤醒/解锁通知漏收)。
                if awayFor >= Self.absenceForceClearCeiling
                    || (awayFor >= Self.absencePollDebounce && self.userIsPresent()) {
                    self.endAbsence(awayFor: awayFor)
                }
                return
            }
```

- [ ] **Step 5: 推送并验证 CI 绿**

```bash
git add Sources/RestEyes/main.swift
git commit -m "feat: poll for return while frozen so missed wake events recover

While an absence is active, the heartbeat also checks real state
(CGDisplayIsAsleep + CGSSessionScreenIsLocked); once away >= 3s and the
user is present, it ends the absence via endAbsence even if the wake/unlock
notification was dropped — the root cause of lid-close getting stuck in rest.
Polling runs only while frozen; normal work has zero overhead.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push
GH_CONFIG_DIR=.gh-config gh run watch
```

预期:CI 绿,`Executed 52 tests, with 0 failures`。

- [ ] **Step 6: 真机验收(不阻塞任务完成)**

- **合盖/锁屏卡休息回归验证**:休息中或工作中合盖,隔一会儿开盖解锁 → **数秒内**回到工作、休息遮罩不滞留。反复多试几次(该 bug 偶发,轮询兜底就是为漏收唤醒通知的情形托底)。
- 长时间(≥ `rest_minutes`)锁屏(Ctrl+Cmd+Q)再解锁 → 回到**全新工作**。
- 短暂(< 去抖 3s)锁一下立刻解 → 不误判,计时接续原样。

---

### Task 5:README 验收清单 + 版本号 + 发布 v0.1.7

**Files:**
- Modify: `README.md`(功能列表、已知边界、手动验收清单)
- Modify: `Resources/Info.plist`(版本 0.1.6/7 → 0.1.7/8)

**Interfaces:** 无代码接口;文档 + 版本 + 发布。

**说明:** 汇总两个功能的真机验收项到 README,并发一个版本。发布依赖 CI:推 `v*` tag 时 workflow 自动 `gh release create`。**`gh release create` 非幂等——同一 tag 的 run 不要重跑**(会因 release 已存在而失败)。

- [ ] **Step 1: 更新功能列表**

`README.md` 中,把:

```
- 休息中主动锁屏/合盖,解锁后直接回到工作(可配置关闭)
```

改为:

```
- 锁屏 / 熄屏 / 合盖离开较久后回来,一律直接回到工作、不卡在休息(短暂解锁是否结束休息由 `wake_ends_rest` 控制)
```

- [ ] **Step 2: 更新已知边界(移除已修复的「纯熄屏检测不到」)**

把:

```
电源键、Ctrl+Cmd+Q 系统锁屏、强制重启无法被用户态应用屏蔽。睡眠或锁屏超过一次休息时长,唤醒后视为已休息,工作计时重新开始。
纯"熄屏"若未触发系统锁屏(未开启"立即要求密码")则检测不到;开启 wake_ends_rest 时,休息刚开始就锁屏再解锁可跳过休息,由用户自律。
```

替换为:

```
电源键、Ctrl+Cmd+Q 系统锁屏、强制重启无法被用户态应用屏蔽。睡眠、锁屏、熄屏、屏保、合盖离开超过一次休息时长,唤醒/解锁后一律视为已休息、工作计时重新开始;偶发漏收唤醒通知的情形由缺席轮询在数秒内兜底解冻。
开启 wake_ends_rest 时,休息刚开始就锁屏再解锁可跳过休息,由用户自律。
```

- [ ] **Step 3: 手动验收清单加三项**

把:

```
- [ ] 休息中锁屏再解锁:默认直接回到工作且不触发锁屏;`wake_ends_rest = off` 时遮罩继续倒计时
```

替换为(原行 + 三条新项):

```
- [ ] 休息中锁屏再解锁:默认直接回到工作且不触发锁屏;`wake_ends_rest = off` 时遮罩继续倒计时
- [ ] 休息**自然结束 + 锁屏**:从黑遮罩直接切到锁屏界面,中途不露出桌面/工作内容
- [ ] 工作中**熄屏或启屏保**超过休息时长后唤醒:工作计时重新开始
- [ ] **合盖**再开盖解锁(反复多次):数秒内回到工作,休息遮罩不滞留
```

- [ ] **Step 4: 版本号 +1**

`Resources/Info.plist`,把:

```xml
    <key>CFBundleShortVersionString</key>
    <string>0.1.6</string>
    <key>CFBundleVersion</key>
    <string>7</string>
```

改为:

```xml
    <key>CFBundleShortVersionString</key>
    <string>0.1.7</string>
    <key>CFBundleVersion</key>
    <string>8</string>
```

- [ ] **Step 5: 提交 + 推送 + CI 绿**

```bash
git add README.md Resources/Info.plist
git commit -m "docs: README + bump to 0.1.7 (away-detection + lock-no-flash)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push
GH_CONFIG_DIR=.gh-config gh run watch
```

预期:CI 绿,`Executed 52 tests, with 0 failures`。

- [ ] **Step 6: 打 tag 发布 v0.1.7**

```bash
git tag v0.1.7
git push origin v0.1.7
GH_CONFIG_DIR=.gh-config gh run watch                 # 盯 tag run(含 release 步骤)绿
GH_CONFIG_DIR=.gh-config gh release view v0.1.7        # 确认 Release 已建、附 RestEyes.zip
```

若 tag run 因网络失败,**不要重跑该 run**(release 非幂等);删 tag 重推:`git push --delete origin v0.1.7 && git tag -d v0.1.7`,再重新 Step 6。

- [ ] **Step 7: 更新项目记忆**

发布成功后,把记忆 `resteyes-project-setup.md` 中的「截至 2026-07-10:v0.1.6 已发布」更新为 v0.1.7 已发布,并补一句本次两项改动(away-detection 兜底 + lock-after-rest 不闪桌面)。
