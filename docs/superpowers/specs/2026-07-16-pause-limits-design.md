# RestEyes 设计:限制连续暂停/跳过

日期:2026-07-16
状态:已确认

关联:在 [2026-07-14-lock-reset-and-lock-on-unlock-design.md](2026-07-14-lock-reset-and-lock-on-unlock-design.md) 之后的独立新功能。**本设计首次改动 `BreakScheduler` 纯逻辑状态机**(此前三份设计均以「不动状态机」为约束),原因见「为什么计数必须进核心」。

## 背景

RestEyes 的护眼强制力目前有缺口:状态栏菜单的「暂停 1 小时」和「跳过下次休息」可以无限次使用。疲劳或赶工时会不断顺手点掉休息,规则形同虚设。

**真实目的:防止连续暂停/跳过。** 不是限制总量——如果每次暂停之间都老老实实休息完了,那想暂停多少次都无所谓,规则的目的已经达到。要堵的是「一次接一次地逃避,中间从不真的休息」。

### 为什么不用「1 小时内 N 次 / 1 天内 N 次」

最初的需求表述是「限制 1 小时内允许暂停的次数,以及 1 天内暂停的次数」。设计过程中发现这是一个**漏的代理指标**,已废弃:

`BreakScheduler.pauseDuration` 为 3600 秒,与「1 小时」窗口**完全相等**,而滚动窗口是半开区间 `(now - 3600, now]`。于是:

```
t=0     点「暂停 1 小时」→ 记录 [0],暂停到 t=3600
t=3600  tick() 走 case .paused → startWork,暂停自动结束
t=3600  再点「暂停 1 小时」→ 窗口 (0, 3600],判 0 > 0 为假
        → t=0 那条记录恰好滑出 → count = 0 → 放行
```

每次暂停结束的**同一瞬间**,那次暂停的配额精确、必然地完全释放,对任何 `limit >= 1` 都成立。连环暂停可无限循环,小时限额永不触发。这不是调参能修的:要拦住第 N 次连环暂停需要窗口 > N × 3600,一个「每小时」窗口在数学上无法约束「时长恰好 1 小时」的暂停。缩短暂停时长也只是把整数倍从 1 变成 2,不消除该性质(窗口是暂停时长的整数倍时,最老那次总在下次尝试的瞬间恰好滑出边界)。

时间窗口是在用时钟去逼近「别连着逃避休息」。**直接对意图建模即无此问题**:计数器不看时钟,只看「上次真的休息是什么时候」。

## 已确认的决策

| # | 决策 | 理由 |
|---|------|------|
| 1 | **暂停与跳过共用同一个连续计数** | 否则「只跳过、不暂停」就能无限逃避,限制失效。 |
| 2 | **连续计数模型**:每次暂停/跳过生效 `+1`,每次真的休息完 `归零`,达上限则两者都禁用 | 直接表达「不许连着逃避休息」。**「暂停 → 老实休息 → 再暂停」永远允许**——因为确实休息了,规则目的已达成。 |
| 3 | **纯内存,不持久化**(重启 RestEyes 即清零) | 用户明确选择。取舍见「风险与取舍」。 |
| 4 | **超限 UI**:菜单项置灰 + 标题写明原因 | 一眼看懂为何点不了、要做什么才能恢复。 |
| 5 | **两个新配置项**:`max_consecutive_skips = 2`、`require_full_rest = on` | 「是否允许连续」是「最多几次」的特例(`= 1` 即不允许连续),故合成一个键。 |
| 6 | **生效时才计数、不退** | 暂停:点击当场 `+1`,提前「恢复计时」不退还。跳过:勾选时不计,等它真的吃掉一次休息那一刻才 `+1`——反复切换开关不烧计数。 |
| 7 | **达上限时,已勾选的跳过被拒绝**,清掉勾选、照常休息 | 最贴合「超过次数则无法跳过休息」,且计数永远不会突破上限。 |
| 8 | **清零看「休息有没有跑满」,不看「休息有没有结束」** | 见下表。`wake_ends_rest` 默认开 → 休息中锁屏 10 秒回来休息就结束了;若「任何结束都清零」,「暂停 → 休息开始 → 锁屏 10 秒 → 回来 → 清零 → 再暂停」即为新的无限循环。 |

### 清零条件

| 休息结束方式 | 跑满? | 是否清零 |
|---|---|---|
| 自然走完(`tick` 到点,`.completed`) | 是 | **总是** |
| 离开期间休息已到点(`systemDidWake` 时 `now >= deadline`,`.wake`) | 是 | **总是** |
| 工作中睡够 `rest_minutes`(`systemDidWake` 长睡,视为已休息) | 是 | **总是** |
| 点「解锁」/ESC×10 提前逃掉(`.unlocked`) | 否 | 看 `require_full_rest` |
| 短暂离开 + `wake_ends_rest` 掐断未跑满的休息(`.wake`) | 否 | 看 `require_full_rest` |

前三行即「长时间离开/合盖/睡眠回来算完整休息」。后两行由 `require_full_rest` 控制,默认 `on`(严格),顺带堵住第三条逃逸路径:`unlock_after` 默认 60 秒,即 3 分钟休息进行到 60 秒解锁按钮就出现,否则「暂停 → 休息 60 秒 → 解锁 → 再暂停」可无限循环。

---

## 架构:计数住在状态机里

**不新增类型。** `BreakScheduler` 加一个计数器:

```swift
public private(set) var consecutiveSkips = 0
```

### 为什么计数必须进核心

`tick()` 中 `else if skipNextArmed { skipNextArmed = false; startWork(now: now) }` 是**跳过真正吃掉一次休息的唯一代码路径**。该分支有两个入口:

- **`working` + armed**(第一个条件因 `!skipNextArmed` 为假而落空):`startWork` 令相位 `working → working`,`transition()` 判 `phase != newPhase` 不成立,**`onPhaseChange` 不触发**——胶水层完全观测不到这次消耗。
- **`warning` + armed**(第一个条件因 `phase == .working` 为假而落空,`BreakSchedulerTests.swift:82` `testSkipNextDuringWarning` 正在测这条路):`startWork` 从 `.warning` 出发,`phase != newPhase` **成立**,`onPhaseChange(.working)` **会触发**。但胶水层无法把它与其他回工作的路径可靠区分开(`onRestEnded` 不发),据此记账等于在回调上叠一层脆弱的推断。

两个入口都不足以让胶水层安全记账。而项目是 **CI-only 编译**(开发机为 Linux,本地无 swift 工具链),纯逻辑的单测是唯一的正确性保障,AppKit 层无法单测。把「能不能暂停」「什么时候计数」放进 `main.swift` 等于放弃验证,故**决策留在核心**。

### 为什么不独立成型

设计早期曾计划把配额做成独立的 `PauseBudget` 类型,理由是「滚动窗口数学(计数、裁剪、恢复时刻、双限额取舍)与相位状态机正交,有成套边界用例」。**改用连续计数模型后该理由消失**:没有窗口数学,剩下的是一个 `Int` 加三行判断,且清零逻辑与 `BreakScheduler` 的休息生命周期深度耦合。独立成型即过度设计。

---

## 状态机改动

### 计数与判定

```swift
/// 连续暂停/跳过次数;每次真的休息完归零。达 max_consecutive_skips 后暂停与跳过均被拒绝。
public private(set) var consecutiveSkips = 0

/// 0 = 不限。
private var skipsExhausted: Bool {
    config.maxConsecutiveSkips > 0 && consecutiveSkips >= config.maxConsecutiveSkips
}
```

### `pause()` 改为返回 `Bool`

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

原 `pause()` 在 `resting`/`paused` 相位**静默 no-op**。菜单虽在 `resting` 时置灰,但 `warning → resting` 恰在点击瞬间切换的竞态下点击会落空;若由调用方无条件计数,就会记下一次**根本没发生的暂停**。现在**相位守卫在前、计数在后**,原子。

### 休息结束统一收口

```swift
/// 结束休息:跑满了就清零连续计数;被提前掐断则看 require_full_rest。
/// startWork 在前、onRestEnded 在后,维持既有回调顺序(见 testRestEndReasonFiresAfterPhaseChange)。
private func endRest(now: Date, reason: RestEndReason, restWasFull: Bool) {
    if restWasFull || !config.requireFullRest { consecutiveSkips = 0 }
    startWork(now: now)
    onRestEnded?(reason)
}
```

三个调用点:

```swift
// tick():休息到点,必然跑满
case .resting:
    endRest(now: now, reason: .completed, restWasFull: true)

// unlock():提前逃掉(unlock_after 按钮 / ESC×10 后门同经此路)
public func unlock(now: Date) {
    guard phase == .resting else { return }
    endRest(now: now, reason: .unlocked, restWasFull: now >= deadline)
}

// systemDidWake() case .resting:区分「离开期间已到点」与「未到点被 wake_ends_rest 掐断」
case .resting:
    if now >= deadline {
        endRest(now: now, reason: .wake, restWasFull: true)
    } else if config.wakeEndsRest {
        endRest(now: now, reason: .wake, restWasFull: false)
    }
    // 未到点且 wake_ends_rest = off:遮罩继续,按墙钟走(不变)
```

`systemDidWake()` 的工作相位长睡分支也清零:

```swift
case .working, .warning:
    if sleptFor >= config.restMinutes * 60 {
        consecutiveSkips = 0                              // 睡够了,视为已休息
        startWork(now: now)
    } else {
        deadline = deadline.addingTimeInterval(sleptFor)  // 睡眠期间计时暂停(不变)
    }
```

`main.swift` 的 `reconcileIfBack()` 在离开 ≥ `rest_minutes` 时调 `systemDidWake(sleptFor: awayFor, now:)`,故「长时间离开回来」经由上述分支清零,胶水层无需改动。

### 工作到点的分流抽成方法

```swift
/// 工作/预警到点:决定走「跳过」「预警」还是「休息」。
/// 跳过只在 armed 且未达上限时生效并 +1;达上限则作废勾选、落回正常路径。
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

`tick()` 中 `case .working, .warning:` 整段替换为 `advancePastWorkDeadline(now: now)`,原三层嵌套条件(含 `!skipNextArmed` 的反向判断)随之捋直。

**「达上限则落回正常路径」而不是直接休息**:armed 状态下原逻辑会绕过预警(`if phase == .working, config.warnSeconds > 0, !skipNextArmed` 因 armed 而不成立)。若拒绝跳过后直接 `startRest`,用户会在毫无预警的情况下突然黑屏。落回正常路径意味着该给的 `warn_seconds` 预警照给。

行为对照(`warn_seconds > 0`):

| armed | 计数 | 相位 | 结果 |
|-------|------|------|------|
| 是 | 未满 | working | 跳过生效,`+1`,重开工作 |
| 是 | 未满 | warning | 跳过生效,`+1`,重开工作 |
| 是 | 已满 | working | 作废勾选 → 预警 → 休息(不计数) |
| 是 | 已满 | warning | 作废勾选 → 直接休息(不计数) |
| 是 | 已满 | working(`warn_seconds = 0`) | 作废勾选 → 直接休息(不计数) |
| 否 | — | working | 预警 |
| 否 | — | warning | 休息 |

### `TickInfo` 携带禁用状态

```swift
public var skipsExhausted: Bool = false   // true = 已达连续上限,暂停与跳过均不可用
```

由 `tickInfo(now:)` 填 `skipsExhausted`(即上文私有计算属性)。字段给默认值,`TickInfo` 的成员逐一初始化器保持向后兼容。

**无需预测式判断**:跳过的计数点在工作 `deadline` 而非 `now`,但 `consecutiveSkips` 在工作相位内**只增不减**(只有休息结束才清零,而休息一旦发生工作相位就结束了)。故「此刻已满」必然蕴含「到点时也满」,菜单按 `now` 置灰不会误禁。反向(此刻未满、到点前因暂停而满)由决策 7 兜住。

---

## 菜单

```swift
func update(phase: Phase, remaining: TimeInterval, skipNextArmed: Bool, skipsExhausted: Bool) {
    // ... countdownItem 部分不变 ...

    // suffix 只在配额是真实致灰原因时才挂:resting 中置灰的原因是「休息中」,与计数无关。
    let suffix = (skipsExhausted && phase != .resting) ? "(已达连续上限,请先完成一次休息)" : ""

    if phase == .paused {
        pauseItem.title = "恢复计时"
        pauseItem.isEnabled = true                                  // 恢复永不被计数禁用
    } else {
        pauseItem.title = "暂停 1 小时\(suffix)"
        pauseItem.isEnabled = phase != .resting && !skipsExhausted
    }

    skipItem.state = skipNextArmed ? .on : .off
    skipItem.title = "跳过下次休息\(suffix)"
    skipItem.isEnabled = phase != .resting && (!skipsExhausted || skipNextArmed)
}
```

三个条件各堵一个死角:

- **`paused` 时「恢复计时」绝不能被禁用**。`pauseItem` 在 `paused` 相位标题是「恢复计时」——用最后一次计数进入暂停后,若禁用逻辑把它一起禁掉,用户会被锁死在暂停里无法提前恢复。
- **已勾选跳过时菜单项必须保持可点**(`|| skipNextArmed`),否则用户无法取消一个已经不会生效的勾选。
- **`resting` 时不挂 suffix**。休息中两项本就因 `phase != .resting` 而置灰,此时显示「请先完成一次休息」会误导——它马上就要休息完了,与计数无关。

`Format` **不改**:提示语是固定文案,无时间格式化需求。

胶水层 `main.swift` 改动极小:

- `onTick` 内 `statusItem.update(...)` 增传 `skipsExhausted: info.skipsExhausted`。
- `onPauseToggle` 闭包**不变**——`pause()` 内部判定,达上限即返回 `false` 静默拒绝;置灰是 UI 防线,核心里的 `guard` 才是真防线,菜单展开瞬间状态变化时点击落空也不会误计数。

---

## 配置变更

`Config` 新增两项:

```swift
public var maxConsecutiveSkips: Int = 2
public var requireFullRest: Bool = true
```

解析仿现有 `warn_seconds` / `lock_after_rest` 的逐键校验回退风格:

```swift
case "max_consecutive_skips":
    if let v = Int(value), (0...100).contains(v) { c.maxConsecutiveSkips = v }
case "require_full_rest":
    if value == "on" { c.requireFullRest = true }
    else if value == "off" { c.requireFullRest = false }
```

`defaultFileContent` 增两行:

```
max_consecutive_skips = 2   # 连续暂停/跳过几次后必须先完成一次休息;1 = 不允许连续;0 = 不限
require_full_rest = on      # 必须完整休息完才清零连续计数;off = 中途点「解锁」也算(on/off)
```

**键名说明**:`skips` 同时涵盖「暂停」与「跳过」——两者共用一个计数(决策 1),注释已写明。

---

## 错误处理

纯内存 + 无时间窗口后,错误面极小,只剩一条:

- **配置值非法或越界**:逐键回退默认值,沿用现有写法,不抛错、不崩溃。`max_consecutive_skips` 校验范围 `0...100`,`0` 即不限,由 `skipsExhausted` 的 `> 0` 前置判断兜住。

无文件 IO、无时间戳、无裁剪、无时钟回拨敏感性——计数器与墙钟完全无关。

---

## 测试与验收

项目 CI-only:本地(Linux)无 swift 工具链,「编译成功/测试通过」一律以 push 后 GitHub Actions macOS runner 的 `swift test` 为准。全部纯逻辑落在 `RestEyesCore` 并配单测,AppKit 层只留不可单测的接线。

### `Tests/RestEyesCoreTests/BreakSchedulerTests.swift`(增补)

沿用 `t0` + `after(_ s:)` + `makeScheduler` 风格;`consecutiveSkips` 为 `public private(set)`,测试经 `@testable import` 直接断言。

**计数与拒绝**

- `pause` 达上限返回 `false`,相位不变、计数不变
- `pause` 成功返回 `true` 且 `consecutiveSkips == 1`
- **`pause` 在 `resting` 相位被相位守卫拒绝时不计数**(钉死「相位守卫在前、计数在后」)
- `resume` 提前恢复**不退还**(计数仍为 1)
- **共用计数**:`pause` 1 次 + 跳过 1 次 = 2,`max=2` 时第三次被拒
- `max_consecutive_skips = 0` 时永不拒绝
- `max_consecutive_skips = 1` 时(不允许连续)第二次即被拒

**跳过的两个入口**(镜像现有 `testSkipNextSkipsOneBreakThenClears` / `testSkipNextDuringWarning`)

- `working` 中 armed + 未满 → 跳过生效,计数 `+1`
- `warning` 中 armed + 未满 → 跳过生效,计数 `+1`
- **`working` 中 armed + 已满 → 作废勾选、照走预警、不计数**
- **`warning` 中 armed + 已满 → 作废勾选、直接休息、不计数**
- `warn_seconds = 0` + armed + 已满 → 直接休息、不计数
- `breakNow` 清 armed 是丢弃不是消耗,**不计数**
- `toggleSkipNext` 反复切换**不计数**

**清零条件**(逐行覆盖「清零条件」表)

- 休息自然走完 → 清零
- `unlock` + `require_full_rest = on` → **不清零**
- `unlock` + `require_full_rest = off` → 清零
- `systemDidWake` 休息中已到点 → 清零(不论 `require_full_rest`)
- `systemDidWake` 休息未到点 + `wake_ends_rest = on` + `require_full_rest = on` → **不清零**
- `systemDidWake` 休息未到点 + `wake_ends_rest = on` + `require_full_rest = off` → 清零
- `systemDidWake` 工作中长睡 ≥ `rest_minutes` → 清零
- `systemDidWake` 工作中短睡 → 不清零、不消耗 armed skip
- `reload(config:)` 只换 config,**不清零计数**

**回归**

- 既有回调顺序不变:`onPhaseChange(.working)` 先于 `onRestEnded`(现有 `testRestEndReasonFiresAfterPhaseChange` 覆盖 `endRest` 重构)
- `TickInfo.skipsExhausted` 正确上报

### `Tests/RestEyesCoreTests/ConfigTests.swift`(增补)

- 两个新键解析、越界回退、默认值(`maxConsecutiveSkips == 2` / `requireFullRest == true`)
- `require_full_rest` 的 `on` / `off` / 非法值
- **`defaultFileContent` 里两个新键的键名可被解析**——独立用例,不能依赖 `testDefaultFileContentRoundTrips`:该测试实现是 `XCTAssertEqual(Config.parse(Config.defaultFileContent), Config())`,而新键的文件值(`2` / `on`)**恰好等于 Swift 侧默认值**,故漏加行、键名拼错(命中 `default: continue`)时它照样绿。须显式断言 `defaultFileContent` 含这两行且解析后取到文件里的值(如临时改用非默认值构造断言,或直接断言字符串含键名)。

### 其余

- 菜单置灰/标题依赖真实 AppKit,不做单测,沿用「本地不编译、以 CI 为准」。
- `Format` 不改,`FormatTests` 不动。

### README 手动验收清单

- 点「暂停 1 小时」→ 点「恢复计时」→ 再点「暂停 1 小时」→ 再点「恢复计时」→ 第三次点「暂停 1 小时」时**菜单项置灰**,标题显示「(已达连续上限,请先完成一次休息)」。(默认 `max=2`;计数不看时钟,故无需卡时间连点。)
- 承上,让一次休息**完整走完** → 两项菜单立即恢复可点。
- 承上,休息中点「解锁」提前结束(默认 `require_full_rest = on`)→ 两项**仍然置灰**;配 `require_full_rest = off` 后同样操作 → 恢复可点。
- 用掉最后一次计数进入暂停后,**「恢复计时」仍可点**。
- 勾选「跳过下次休息」后用暂停耗尽计数 → 工作到点时**照常预警并休息**,勾选被清除,计数不再增加。
- 勾选状态下达上限 → 菜单项**仍可点**以取消勾选。
- 休息中观察:两项虽置灰,标题**不带**「已达连续上限」后缀。
- 合盖/睡眠超过 `rest_minutes` 后唤醒 → 计数清零,两项恢复可点。
- 退出并重开 RestEyes → 计数清零(已知取舍)。

---

## 风险与取舍

- **纯内存态 = 重启即清零**(用户明确选择)。想绕过限制的人退出重开 RestEyes 即可,限制的定位是**防手滑、防惯性**,不是防自己作弊。换来的收益是删掉整条持久化链路:无文件读写、无序列化、无损坏/权限失败的降级路径、无双实例并发问题。
- **升级即被限**:默认 `max_consecutive_skips = 2` 对老用户是**静默的行为变更**(`config.txt` 已存在时 `Config.load` 不会重写,新键缺失即取默认值)。README 须醒目说明,`max_consecutive_skips = 0` 可恢复旧行为。
- **`require_full_rest = on` 默认值是第二处行为变更**:休息中点「解锁」不再清零计数,连续逃避两次后必须真的休息完一次。这正是防护意图,不需要者配 `off`。
- **首次改动 `BreakScheduler`**:此前三份设计均以「不动状态机」为约束。此处必须打破——跳过的消耗点在核心内部,而 CI-only 要求判断逻辑可单测。改动面:`pause()` 签名、两个私有方法(`endRest` / `advancePastWorkDeadline`)、一个计数器、`TickInfo` 一个字段。
- **`pause()` 签名变更**:`Void → @discardableResult Bool`。现有调用点(`main.swift` 的 `onPauseToggle`、单测)无需改写即可编译。
- **不限制总量**:「暂停 1 小时 → 老实休息 3 分钟 → 再暂停 1 小时」可以无限重复,一天下来大部分时间处于暂停中。这是模型的**有意选择**(决策 2):既然每次之间都完整休息了,护眼目的已达成。想额外卡总量需要另一套机制,本设计不做。
- **达上限时勾选的跳过被静默作废**:用户的意图消失,仅在菜单标题体现。备选(保留勾选待计数清零后自动生效)被否——休息完之后突然跳过一次休息更意外。
- **ESC×10 后门与解锁按钮同路**:二者同经 `unlock()`,故 `require_full_rest = on` 下都不清零。ESC×10 仍能强制结束卡住的遮罩(永不被拒绝),只是不再顺带清零计数。

## 代码触点

- **`Sources/RestEyesCore/BreakScheduler.swift`**:加 `consecutiveSkips` 计数器与 `skipsExhausted` 计算属性;`pause()` 返回 `Bool` 并内查上限;新增 `endRest(now:reason:restWasFull:)` 收口三个休息结束点;`tick()` 的 `case .working, .warning` 抽为 `advancePastWorkDeadline(now:)` 并接入跳过计数与拒绝;`systemDidWake()` 的休息分支拆「已到点/被掐断」、工作长睡分支清零;`TickInfo` 加 `skipsExhausted`。
- **`Sources/RestEyesCore/Config.swift`**:新增 `maxConsecutiveSkips` / `requireFullRest` 字段、两个 `case` 解析、`defaultFileContent` 增两行。
- **`Sources/RestEyes/StatusItem.swift`**:`update` 签名增 `skipsExhausted`;`pauseItem` / `skipItem` 的标题与 `isEnabled` 按上述规则重算。
- **`Sources/RestEyes/main.swift`**:`onTick` 内 `statusItem.update(...)` 增传一个参数。**仅此一处。**
- **`Tests/RestEyesCoreTests/BreakSchedulerTests.swift`**、**`ConfigTests.swift`**:见「测试与验收」。
- **`README.md`**:配置表增两键 + 已知边界(升级即被限、`require_full_rest` 行为变更、重启清零、不限总量)+ 手动验收清单。
- **不改**:`Format.swift`、`OverlayController.swift`、`ScreenLocker.swift`、`LoginItem.swift`。**不新增类型或文件。**
