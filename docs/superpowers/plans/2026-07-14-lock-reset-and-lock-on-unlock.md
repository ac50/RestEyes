# Lock-reset (no-freeze) + no-flash lock + lock_on_unlock — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace RestEyes' complex absence freeze/poll/watchdog model with a simple no-freeze one (timer always runs; away = lock/display-off/screensaver suppresses rest UI and resets on long return), make the rest-end lock removal keyless & flash-free, and add `lock_on_unlock` so the unlock button / ESC×10 route through the system lock screen.

**Architecture:** All behavior changes live in the AppKit glue (`Sources/RestEyes/main.swift`); the only new config is `lock_on_unlock` in `Sources/RestEyesCore/Config.swift`. The pure state machine `BreakScheduler`, `ScreenLocker`, and `OverlayController` are NOT modified — "reset to fresh work" reuses `scheduler.systemDidWake(sleptFor:now:)`, and rest-UI suppression is done by the glue choosing whether to call `overlay.showRest`/`showWarning`.

**Tech Stack:** Swift + AppKit (SPM), macOS 26+, Apple Silicon. Zero third-party deps.

**Spec:** `docs/superpowers/specs/2026-07-14-lock-reset-and-lock-on-unlock-design.md` — read it for the full rationale behind each change.

## Global Constraints

- **Do NOT modify** `BreakScheduler.swift`, `ScreenLocker.swift`, `OverlayController.swift`, `Format.swift`, `LoginItem.swift`, `StatusItem.swift`. Changes are confined to `main.swift`, `Config.swift`, `ConfigTests.swift`, `README.md`, `Resources/Info.plist`.
- **No new config except `lock_on_unlock`.** The reset threshold reuses the existing `rest_minutes`. Non-boolean/invalid config values must fall back to the default, never crash.
- **`lock_on_unlock` default = `on`** (i.e. `Config.lockOnUnlock` default `true`, and `defaultFileContent` says `on`, so `testDefaultFileContentRoundTrips` still holds).
- **Local build/test is NOT available** (macOS AppKit app; project convention is "本地不编译、以 GitHub Actions 为准"). Every "verify" step = commit, push, and confirm the GitHub Actions `swift test` + build job is green (`gh` uses this repo's config prefix — see `.gh-config/`). Glue behavior (`main.swift`) has no unit tests per the spec; its gate is a green CI **build** plus the manual acceptance items listed in each task.
- **Comments are Chinese**, matching the existing file style. Keep new comments consistent in tone/density with surrounding code.
- **`message` / config strings** cannot contain `#` (parser strips from first `#`) and are whitespace-trimmed — irrelevant to `lock_on_unlock` (a boolean) but keep the `defaultFileContent` comment style.

---

## File Structure

- `Sources/RestEyesCore/Config.swift` — **Modify.** Add `lockOnUnlock` field, `lock_on_unlock` parse case, `defaultFileContent` line. (Task 1)
- `Tests/RestEyesCoreTests/ConfigTests.swift` — **Modify.** Add `lock_on_unlock` parse/default/invalid tests. (Task 1)
- `Sources/RestEyes/main.swift` — **Modify.** The bulk: remove the absence freeze/poll/watchdog machinery, add the no-freeze away model + reconcile-on-return + rest-UI suppression + `onRestEnded` routing (Task 2); make the rest-end lock removal keyless (Task 3). (Tasks 2, 3)
- `README.md` — **Modify.** Config table + known-boundaries + manual acceptance checklist. (Task 4)
- `Resources/Info.plist` — **Modify.** Version bump `0.1.10`→`0.1.11`, build `11`→`12`. (Task 4)

Task order: **1 → 2 → 3 → 4.** Task 2 depends on Task 1 (`config.lockOnUnlock`). Task 3 depends on Task 2 (the `onRestEnded` lock path it refines). Task 4 depends on all.

---

## Task 1: Config `lock_on_unlock`

**Files:**
- Modify: `Sources/RestEyesCore/Config.swift`
- Test: `Tests/RestEyesCoreTests/ConfigTests.swift`

**Interfaces:**
- Produces: `Config.lockOnUnlock: Bool` (default `true`); parser key `lock_on_unlock` (`on`/`off`). Consumed by `main.swift` in Task 2.

- [ ] **Step 1: Write failing tests**

Add to `Tests/RestEyesCoreTests/ConfigTests.swift` (inside the `ConfigTests` class), matching the existing test style used for `wake_ends_rest` / `lock_after_rest`:

```swift
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
```

- [ ] **Step 2: Verify tests fail (CI)**

Since local build is unavailable, this step is satisfied by Step 5's CI run showing these four tests failing to compile (`lockOnUnlock` unknown) before Step 3. If you prefer a strict red first, commit+push only this step and confirm the CI `swift test` job fails with "value of type 'Config' has no member 'lockOnUnlock'". Otherwise proceed to Step 3 and rely on the green run in Step 5.

- [ ] **Step 3: Add the `lockOnUnlock` field**

In `Sources/RestEyesCore/Config.swift`, add the field right after `launchAtLogin` (currently line 17):

```swift
    public var launchAtLogin: Bool = true
    public var lockOnUnlock: Bool = true
```

- [ ] **Step 4: Add the parse case and the default-file line**

In `Config.swift` `parse(_:)`, add a case alongside the other booleans (after the `launch_at_login` case, ~line 83):

```swift
            case "lock_on_unlock":
                if value == "on" { c.lockOnUnlock = true }
                else if value == "off" { c.lockOnUnlock = false }
```

And in `defaultFileContent`, add a line after the `launch_at_login` line (~line 34):

```
    launch_at_login = on   # 开机自动启动(on/off)
    lock_on_unlock = on    # 点击「解锁」或 ESC×10 后进入系统锁屏,需输开机密码才回桌面(on/off)
    """
```

(Keep the closing `"""` of the multiline string on its own line as before.)

- [ ] **Step 5: Verify tests pass (CI)**

Run: `git add -A && git commit -m "feat(config): add lock_on_unlock (default on)" && git push`, then watch CI:
`gh run watch` (with this repo's gh config).
Expected: `swift test` job GREEN — the four new tests pass and the existing `testDefaultFileContentRoundTrips` still passes (default `on` round-trips to `Config()`).

- [ ] **Step 6: (commit already done in Step 5.)**

---

## Task 2: No-freeze away model + rest-UI suppression + `onRestEnded` routing (problems ① & ③)

**Files:**
- Modify: `Sources/RestEyes/main.swift`

**Interfaces:**
- Consumes: `Config.lockOnUnlock` (Task 1); existing `scheduler.systemDidWake(sleptFor:now:)`, `scheduler.phase`, `scheduler.config`, `overlay.showRest(config:)`, `overlay.hideRest()`, `overlay.showWarning(secondsRemaining:)`, `overlay.detachRestInteraction()`, `ScreenLocker.lock()`.
- Produces: `isAway` (computed), `awayBeganAt`, `noteAwayBegan()`, `reconcileIfBack()`, `observeAwayNotifications()`. Task 3 refines the lock-removal helpers this task leaves in place (`startLockConfirmFallback()`, `finishPendingRestWindowRemoval()`, and the `screenIsLocked` observer body).

This task is one cohesive rewrite of the absence model in `main.swift`. Do the edits in order; the file must compile after Step 7.

- [ ] **Step 1: Rename the timestamp field and drop the two dead constants**

In the stored-property block (top of `AppDelegate`): rename `absenceBeganAt` → `awayBeganAt` and delete the watchdog + poll-debounce constants.

Replace line 12:
```swift
    private var absenceBeganAt: Date?
```
with:
```swift
    private var awayBeganAt: Date?            // 离开(锁屏/熄屏/屏保)起点;不冻结,仅用于回来时算离开时长
```

Delete the constant at line 22 (`absenceForceClearCeiling`) and its doc comment (line 21), and the constant at line 28 (`absencePollDebounce`) and its doc comment (line 27). Keep `lockConfirmFallback` (line 25) and `suspendJumpThreshold` (line 32).

- [ ] **Step 2: Simplify the heartbeat — always tick, keep only clock-jump**

Replace the whole `startTicking()` body's timer closure (currently lines 136-161, the `if let began = self.absenceBeganAt { ... } ... if gap >= ...` block) with:

```swift
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            let gap = now.timeIntervalSince(self.lastTickAt)
            self.lastTickAt = now

            if gap >= Self.suspendJumpThreshold {
                // 心跳间隔异常大 = 系统被挂起(睡眠/合盖)。按跳变时长对账,交 systemDidWake 处理。
                self.scheduler.systemDidWake(sleptFor: gap, now: now)
                return
            }
            self.scheduler.tick(now: now)          // 离开(锁屏/熄屏/屏保)时也照常走,不冻结
        }
```

(The `lastTickAt = Date()` line before the timer, `timer.tolerance`, `RunLoop.main.add`, and `tickTimer = timer` lines stay unchanged.)

- [ ] **Step 3: Add `isAway` and rename `noteAbsenceBegan` → `noteAwayBegan`**

Add a computed property near the other private helpers (e.g. just above `noteAwayBegan`):

```swift
    /// 是否处于「离开」态(锁屏/熄屏/屏保任一)。用于抑制离开期间的休息 UI 与锁屏。
    private var isAway: Bool { isScreenLocked || isDisplayAsleep || isScreensaverActive }
```

Replace `noteAbsenceBegan()` (lines 206-208):
```swift
    private func noteAwayBegan() {
        if awayBeganAt == nil { awayBeganAt = Date() }
    }
```

- [ ] **Step 4: Replace `endAbsenceIfPresent`/`endAbsence` with `reconcileIfBack` (the return rule)**

Delete `endAbsenceIfPresent()` (lines 210-214) and `endAbsence(awayFor:)` (lines 217-223), and delete `userIsPresent()` (lines 226-231) and `screenIsLockedNow()` (lines 235-238) entirely (the semi-private `CGSSessionScreenIsLocked` key goes with them). Add in their place:

```swift
    /// 三个离开标记全清(解锁 且 亮屏 且 屏保停)= 用户真回来了 → 收口对账,一律落在工作态。
    /// 计时器离开期间照常走,故这里只在「离开够久」时重置;短暂离开不动(不补偿)。
    private func reconcileIfBack() {
        guard !isScreenLocked, !isDisplayAsleep, !isScreensaverActive,
              let began = awayBeganAt else { return }
        awayBeganAt = nil
        let now = Date()
        let awayFor = now.timeIntervalSince(began)
        switch scheduler.phase {
        case .resting:
            // 离开期间进了休息(遮罩被抑制):结束它。wake_ends_rest=on 回工作;
            // off 且未到点则休息继续,此时把遮罩显示出来(与该开关语义一致)。
            scheduler.systemDidWake(sleptFor: awayFor, now: now)
            if scheduler.phase == .resting {
                overlay.showRest(config: scheduler.config)   // 下一次 onTick 会刷新倒计时
            }
        case .working, .warning:
            if awayFor >= scheduler.config.restMinutes * 60 {
                scheduler.systemDidWake(sleptFor: awayFor, now: now)   // → startWork 全新工作
            }
            // < rest_minutes:什么都不做(计时器本就照常走着)
        case .paused:
            break
        }
    }
```

- [ ] **Step 5: Rewire the away observers (rename call + method)**

Rename `observeAbsenceNotifications()` → `observeAwayNotifications()` (also update the call site in `applicationDidFinishLaunching`, currently `observeAbsenceNotifications()` at line 41). In its body, replace every `noteAbsenceBegan()` with `noteAwayBegan()` and every `endAbsenceIfPresent()` with `reconcileIfBack()`. Leave the `finishPendingRestWindowRemoval()` call inside the `com.apple.screenIsLocked` observer UNCHANGED (Task 3 refines it). Also update the MARK comment above it:

```swift
    // MARK: - 离开检测(锁屏/熄屏/屏保);不冻结计时,仅在回来时按离开时长决定是否重置。
    //         系统挂起(睡眠/合盖:CPU 关、时钟跳)由心跳的时钟跳变兜底,不在此处理。
    private func observeAwayNotifications() {
```

- [ ] **Step 6: Suppress rest/warning UI while away, and rewrite `onRestEnded`**

In `wire()`:

In `onPhaseChange` (lines 51-66), gate the two "show" calls on `!isAway`:
```swift
            case .warning:
                if !isAway { overlay.showWarning(secondsRemaining: scheduler.config.warnSeconds) }
            case .resting:
                overlay.hideWarning()
                if !isAway { overlay.showRest(config: scheduler.config) }
```
(`.working` and `.paused` cases unchanged.)

In `onTick` (lines 68-81), gate the warning refresh on `!isAway`:
```swift
            case .warning:
                if !isAway { overlay.showWarning(secondsRemaining: Int(info.remaining.rounded())) }
```
(The `.resting` `updateRest` call is a no-op when the shield was suppressed — it guards on `isShieldActive` — so leave it unchanged. `statusItem.update(...)` stays unchanged.)

Replace the entire `onRestEnded` closure (lines 84-96) with:
```swift
        // 退出 resting 只有 completed/unlocked/wake 三条路,都经此回调。
        // 是否锁屏由胶水层依配置决定;离开期间(isAway)一律不锁,只撤遮罩。
        scheduler.onRestEnded = { [weak self] reason in
            guard let self else { return }
            let shouldLock = !self.isAway && (
                (reason == .completed && self.scheduler.config.lockAfterRest) ||
                (reason == .unlocked  && self.scheduler.config.lockOnUnlock)
            )
            if shouldLock {
                // 先停交互(让用户能输密码),黑窗保留;锁屏后再撤黑窗(见 Task 3 的确认撤窗)。
                self.overlay.detachRestInteraction()
                ScreenLocker.lock()
                self.pendingRestWindowRemoval = true
                self.startLockConfirmFallback()
            } else {
                self.overlay.hideRest()
            }
        }
```

- [ ] **Step 7: Verify build + manual acceptance, then commit**

Run: `git add -A && git commit -m "feat(away): no-freeze away model; suppress rest while away; lock_on_unlock routing" && git push`, then `gh run watch`.
Expected: CI **build** job GREEN (compiles; no references to removed `absenceBeganAt`/`userIsPresent`/`screenIsLockedNow`/`absenceForceClearCeiling`/`absencePollDebounce`). Existing `swift test` still green (no test touched).

Manual acceptance (real Mac, from the spec's checklist — record results):
- Work, lock screen (no lid) > `rest_minutes`, unlock → **fresh work period**.
- Work, lock screen < `rest_minutes`, unlock → **resumes prior work, does NOT drop into a rest**.
- While locked, even if the internal timer reaches a boundary → **no rest overlay appears behind the lock, no extra lock fires**; same for display-off / screensaver.
- `lock_on_unlock = on` (default): during a rest, click 解锁 → **system lock screen appears** (needs OS password); ESC×10 → also lands at the lock screen. Set `lock_on_unlock = off`, reload → 解锁 returns straight to desktop.

Also: in Step 4, after deleting `userIsPresent()`/`screenIsLockedNow()`, the `import CoreGraphics` at `main.swift:2` becomes unused (its only users were `CGDisplayIsAsleep`/`CGMainDisplayID`/`CGSessionCopyCurrentDictionary`). Remove that import line. (If CI build unexpectedly fails on a missing CG symbol, restore it — but it should be clean.)

---

## Task 3: Keyless, flash-free rest-end lock removal (problem ②)

**Files:**
- Modify: `Sources/RestEyes/main.swift`

**Interfaces:**
- Consumes: `pendingRestWindowRemoval` (already in the file), `overlay.removeRestWindows()` (existing), the `com.apple.screenIsLocked` observer body from Task 2, `startLockConfirmFallback()`/`finishPendingRestWindowRemoval()` (existing).
- Produces: `scheduleRemovalAfterGrace()`; constant `lockRemovalGrace`; retunes `lockConfirmFallback` to a 5s ceiling. No signature seen by other tasks.

Rationale: the old code removed the shield on the bare `screenIsLocked` edge and, worse, on an **unconditional 2.5s** timer — which can strip the shield before the lock UI covers the desktop. New: remove only after the lock notification **plus a short composite grace**, with a longer unconditional ceiling as the only backstop. No semi-private key involved.

- [ ] **Step 1: Retune constants — 5s ceiling + 0.4s grace**

Replace the `lockConfirmFallback` constant and its doc comment (currently `main.swift:24-25`):
```swift
    /// 锁屏确认后再等这点时间(合成缓冲),让锁屏界面完全画完再撤黑窗,消除露桌面那一帧。
    private static let lockRemovalGrace: TimeInterval = 0.4

    /// 兜底硬上限:超时仍没收到 screenIsLocked 就直接撤黑窗,防滞留。
    /// 常态走「通知 + 缓冲」快路(几百毫秒内撤),兜底几乎不触发。
    private static let lockConfirmFallback: TimeInterval = 5
```

- [ ] **Step 2: Drive removal from the notification + grace (not immediately)**

In `observeAwayNotifications()`, in the `com.apple.screenIsLocked` observer body, replace the immediate call:
```swift
            self?.finishPendingRestWindowRemoval()   // 锁屏界面已盖上 → 撤掉延迟保留的黑窗
```
with the grace-delayed version:
```swift
            self?.scheduleRemovalAfterGrace()   // 锁屏确认 → 等合成缓冲后撤黑窗(见下)
```
(Leave `self?.isScreenLocked = true` and `self?.noteAwayBegan()` above it unchanged.)

- [ ] **Step 3: Add `scheduleRemovalAfterGrace()`**

Add next to `finishPendingRestWindowRemoval()`:
```swift
    /// 收到 com.apple.screenIsLocked 后,等一个合成缓冲再撤黑窗:此刻锁屏界面已在黑窗之上,
    /// 撤窗发生在其下方、不可见。非「休息结束锁屏」路(pending 为假)时安全 no-op。
    private func scheduleRemovalAfterGrace() {
        guard pendingRestWindowRemoval else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lockRemovalGrace) { [weak self] in
            self?.finishPendingRestWindowRemoval()
        }
    }
```
`startLockConfirmFallback()` and `finishPendingRestWindowRemoval()` are unchanged: the ceiling timer now fires at 5s (via the retuned constant) and both removal paths funnel through the idempotent `finishPendingRestWindowRemoval()` (its `guard pendingRestWindowRemoval` + `lockConfirmFallbackTimer?.invalidate()` make double-calls safe and cancel the ceiling once removal happens). Update the doc comment on `startLockConfirmFallback()` to say "兜底上限(约 5s)".

- [ ] **Step 4: Verify build + manual acceptance, then commit**

Run: `git add -A && git commit -m "fix(lock): remove rest shield on lock notification + grace, 5s ceiling (no desktop flash)" && git push`, then `gh run watch`.
Expected: CI build GREEN; `swift test` still GREEN.

Manual acceptance (real Mac):
- `lock_after_rest = on`, let a rest finish naturally **while present** → screen goes **black → lock screen with NO desktop/work-content flash** in between. Repeat several times.
- `lock_on_unlock = on`, during a rest click 解锁 → same seamless black → lock screen (this path reuses the same removal).

---

## Task 4: Docs + version bump

**Files:**
- Modify: `README.md`
- Modify: `Resources/Info.plist`

**Interfaces:** none (docs/metadata only).

- [ ] **Step 1: Config table row**

In `README.md`, add a row after the `launch_at_login` row (~line 39):
```
| `lock_on_unlock` | `on` | 点击「解锁」或 ESC×10 后进入系统锁屏,需输开机密码才回桌面(`on`/`off`) |
```

- [ ] **Step 2: Feature list + known-boundaries wording**

In the feature list (~line 11), replace the away line so it reflects the new model (no freeze; away just runs and resets on long return, and no rest behind the lock):
```
- 锁屏 / 熄屏 / 屏保 / 合盖期间计时照常走、不在后台弹休息;离开超过一次休息时长后回来,工作计时重新开始(短暂离开则接着原工作)
```
In "已知边界" (~lines 49-51), update the paragraph that described the old freeze/watchdog behavior to state: 计时不冻结;离开(锁屏/熄屏/屏保)超过一次休息时长,回来即视为已休息、工作计时重开;短暂离开跳过这次休息、接着原工作。Remove any mention of「缺席轮询/1 小时看门狗」(no longer exists).

- [ ] **Step 3: Manual acceptance checklist items**

Append to the checklist (~after line 72):
```
- [ ] 仅锁屏(不合盖)离开 ≥ 休息时长再解锁:工作计时重新开始;< 休息时长:接着原工作、不会一解锁就进休息
- [ ] 锁屏 / 熄屏 / 屏保期间即使内部到点,也不在后台弹遮罩、不额外锁屏
- [ ] 休息**自然结束 + 锁屏**:黑遮罩直接切锁屏界面,中途不露桌面(在场时)
- [ ] `lock_on_unlock = on`(默认):休息中点「解锁」或 ESC×10 → 进系统锁屏、需输开机密码;`off` 重载后 → 直接回桌面
```

- [ ] **Step 4: Version bump**

In `Resources/Info.plist`: `CFBundleShortVersionString` `0.1.10` → `0.1.11` (line 20); `CFBundleVersion` `11` → `12` (line 22).

- [ ] **Step 5: Commit**

Run: `git add -A && git commit -m "docs: README + bump 0.1.11 (no-freeze away model, lock_on_unlock, no-flash lock)" && git push`, then `gh run watch`.
Expected: CI GREEN.

---

## Self-Review

**1. Spec coverage** (each spec section → task):
- 问题① no-freeze away model, suppress rest while away, reset-on-long-return, delete watchdog/poll/key → **Task 2**. Reset threshold = `rest_minutes` → Task 2 Step 4. Delete semi-private key → Task 2 Step 4 (+ CoreGraphics import note).
- 问题② keyless notification + 0.4s grace + 5s ceiling → **Task 3**.
- 问题③ `lock_on_unlock` config → **Task 1**; `onRestEnded` `.unlocked && lockOnUnlock` routing (+ ESC×10 via same path, `.wake` never locks, away never locks) → **Task 2 Step 6**.
- Config default/round-trip → **Task 1**. README + version → **Task 4**. `BreakScheduler`/`ScreenLocker`/`OverlayController` untouched → honored (only `main.swift`/`Config` code).
- `wake_ends_rest = off` surface-on-return edge → **Task 2 Step 4** (`reconcileIfBack` resting branch re-shows the shield).

**2. Placeholder scan:** No TBD/TODO; every code step has full code; the two README prose tweaks (Step 2) name the exact content to write. OK.

**3. Type consistency:** `awayBeganAt: Date?`, `isAway: Bool`, `noteAwayBegan()`, `reconcileIfBack()`, `observeAwayNotifications()`, `scheduleRemovalAfterGrace()`, `lockRemovalGrace`, `lockConfirmFallback` (retuned to 5), `Config.lockOnUnlock` — names are used identically across Tasks 1–3. `reconcileIfBack` reuses `scheduler.systemDidWake(sleptFor:now:)` and `scheduler.phase`/`.config.restMinutes` (existing signatures). `onRestEnded` reuses `overlay.detachRestInteraction()`/`hideRest()` and `startLockConfirmFallback()`/`pendingRestWindowRemoval` (existing). No dangling references.

