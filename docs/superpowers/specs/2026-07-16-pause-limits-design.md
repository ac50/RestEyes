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
| 7 | **达上限时,已勾选的跳过被拒绝**,清掉勾选、照常休息 | 最贴合「超过次数则无法跳过休息」。(计数可能短暂**超过**上限——见决策 9;`skipsExhausted` 用 `>=` 判定,行为仍正确。) |
| 8 | **休息跑满 → 归零** | 「暂停 → 老实休息 → 再暂停」永远允许。 |
| 9 | **休息没跑满 → `+1`**(`require_full_rest = on` 时) | 决策 8 的**对偶**。只「不清零」是不够的:掐断休息这条路本就不消耗计数,对它而言「不清零」等于零惩罚,于是成为零成本、不计数、无上限的逃避路径——**比点暂停还省事**,`max_consecutive_skips` 永不触发。见下。 |

### 为什么「没跑满」必须计数而不只是「不清零」

```
休息一开始就合盖 6 秒再打开(默认配置,无需菜单、无需密码)
  → main.swift:143 判 gap >= suspendJumpThreshold(5) → systemDidWake(sleptFor: 6)
  → 休息未到点 + wake_ends_rest = on(默认)→ 休息结束、白得一整个 work_minutes
  → 若只「不清零」:consecutiveSkips 纹丝不动 → 每周期重复即可永久逃避
```

休息中锁屏/启屏保 1 秒(经 `main.swift` `reconcileIfBack` 的 `.resting` 分支)、以及「休息 60 秒 → 点解锁」(`unlock_after` 默认 60)同理。决策 2 写了「每次真的休息完 → 归零」,对偶的另一半是「**每次没休息完,也算一次逃避**」。

### 清零条件

判据是 **`restWasFull`**:本次休息是否真的跑满,或用户是否已用「离开/睡眠」抵掉了一次休息。

| 休息结束方式 | `restWasFull` | `require_full_rest = on` | `= off` |
|---|---|---|---|
| 自然走完(`tick` 到点,`.completed`) | 是 | **归零** | 归零 |
| 离开期间休息已到点(`now >= deadline`,`.wake`) | 是 | **归零** | 归零 |
| 解锁时休息其实已到点(`unlock()` 且 `now >= deadline`) | 是 | **归零** | 归零 |
| 未到点被 `wake_ends_rest` 掐断,但离开/睡眠 ≥ `rest_minutes`(`.wake`) | 是 | **归零** | 归零 |
| 未到点被 `wake_ends_rest` 掐断,离开很短(`.wake`) | 否 | **`+1`** | 归零 |
| 点「解锁」/ESC×10 提前逃掉(`now < deadline`,`.unlocked`) | 否 | **`+1`** | 归零 |

另有一条不经休息相位的清零:**任何相位下,离开/睡眠 ≥ `rest_minutes` 即视为已休息 → 归零**(含 `.paused`,见「状态机改动」)。这就是「长时间离开/合盖/睡眠回来算完整休息」。

`require_full_rest` 默认 `on`(严格),顺带堵住第三条逃逸路径:`unlock_after` 默认 60 秒,即 3 分钟休息进行到 60 秒解锁按钮就出现,否则「暂停 → 休息 60 秒 → 解锁 → 再暂停」可无限循环。设 `off` 则任何休息结束都归零(宽松,保留该路径)。

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
/// 结束休息:跑满了就清零连续计数;没跑满则算一次逃避 +1(require_full_rest = off 时一律清零)。
/// startWork 在前、onRestEnded 在后,维持既有回调顺序(见 testRestEndReasonFiresAfterPhaseChange)。
private func endRest(now: Date, reason: RestEndReason, restWasFull: Bool) {
    if restWasFull || !config.requireFullRest {
        consecutiveSkips = 0
    } else {
        consecutiveSkips += 1        // 没跑满 = 一次逃避,占额度(见决策 9)
    }
    startWork(now: now)
    onRestEnded?(reason)
}
```

三个调用点:

```swift
// tick():休息到点,必然跑满
case .resting:
    endRest(now: now, reason: .completed, restWasFull: true)

// unlock():提前逃掉(unlock_after 按钮 / ESC×10 后门同经此路)。
// now >= deadline 只在「已到点但本秒 tick 还没跑」的 ~1 秒窗口内为真,此时休息其实已走完。
public func unlock(now: Date) {
    guard phase == .resting else { return }
    endRest(now: now, reason: .unlocked, restWasFull: now >= deadline)
}

// systemDidWake() case .resting:区分「已到点」「未到点但离开够久」「未到点且离开很短」
case .resting:
    if now >= deadline {
        endRest(now: now, reason: .wake, restWasFull: true)
    } else if config.wakeEndsRest {
        // 未到点被掐断:离开/睡眠够一次休息时长也算休息过了,否则记一次逃避。
        endRest(now: now, reason: .wake, restWasFull: sleptFor >= config.restMinutes * 60)
    }
    // 未到点且 wake_ends_rest = off:遮罩继续,按墙钟走(不变)
```

**`.resting` 分支必须看 `sleptFor`,否则「离开越久反而越惨」**。离开可以**早于**休息开始(离开期间计时不冻结,遮罩被抑制),于是能出现「离开很久但休息刚开始没多久」:

```
work=20/rest=3。t=0 锁屏(计时照常走)→ t=20 休息开始(遮罩被抑制)
→ t=22 解锁 → awayFor = 22 分钟,但 now(22) < deadline(23)
→ 若只看 now >= deadline → restWasFull = false → +1
```

离开 22 分钟反被记一次逃避。加上 `sleptFor >= rest_minutes` 这一支即消除该非单调性。注意判据仍在 `else if config.wakeEndsRest` **之内**,故 `wake_ends_rest = off` + 未到点时休息继续的既有行为不变。

### 「离开够久 = 已休息」的清零提到相位判断之前

```swift
public func systemDidWake(sleptFor: TimeInterval, now: Date) {
    // 睡/离开够一次休息时长 = 视为已休息,任何相位一律清零(含 .paused)。
    if sleptFor >= config.restMinutes * 60 { consecutiveSkips = 0 }

    switch phase {
    case .resting:
        // ……见上
    case .working, .warning:
        if sleptFor >= config.restMinutes * 60 {
            startWork(now: now)                              // 睡够了,视为已休息(不变)
        } else {
            deadline = deadline.addingTimeInterval(sleptFor) // 睡眠期间计时暂停(不变)
        }
    case .paused:
        break                                                // 暂停按墙钟,不补偿(不变)
    }
}
```

**必须提到 `switch` 之前,否则 `.paused` 相位永不清零**:计数已满时点暂停 → 合盖过夜 → 回来计数仍是满的,必须先完整休息一次才能再暂停。这与「长时间离开/合盖/睡眠回来算完整休息」直接矛盾。原 `case .paused: break`(`BreakScheduler.swift:114`)与 `main.swift` `reconcileIfBack()` 的 `case .paused: break` 都不会触发清零。

配套改 `main.swift` 的 `reconcileIfBack()`,让暂停相位下的「离开回来」也能抵账:

```swift
case .paused:
    scheduler.systemDidWake(sleptFor: awayFor, now: now)   // 仅为「离开够久 → 清零计数」;暂停本身不补偿
```

`systemDidWake` 的 `.paused` 分支除顶部清零外什么都不做,故此调用不改变暂停的截止时刻,与 2026-07-14 设计的「暂停按墙钟、不补偿」一致。`.working`/`.warning`/`.resting` 三个分支的既有接线不变。

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

### `reload()` 堵掉一键免费跳过

**这是既有代码里的洞,不修则本功能失效**。`reload(config:now:)` 在 `.working`/`.warning` 相位**无条件** `startWork(now:)`,即便配置一个字节都没变;而「重新加载配置」菜单项从不置灰(`menu.autoenablesItems = false`,`isEnabled` 默认 `true` 从未被改写)。于是在 `.warning` 相位(黑屏还有 10 秒)点一下它 → `startWork` → 休息被取消、白得一整个 `work_minutes`、计数不变。**比点暂停还省事,且完全不计数。**

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

`.warning` 一律不动 `deadline`,让预警走完照常进休息。既有三条 reload 单测(`testReloadDuringWorkingRestartsWithNewDuration` 用 work 1→2、`testReloadDuringRestingKeepsRestDeadline`、`testReloadWhilePausedKeepsPause`)全部仍绿。

副带收益:改 `message` 之类与时长无关的配置不再重置工作倒计时——`reloadConfigIfChanged` 每个工作周期开头都会跑,原先任何配置变动都会白送一次计时重开。

残余路径「手改 `work_minutes` 再 reload」需要编辑配置文件,与「改 `max_consecutive_skips = 0`」同属「风险与取舍」已接受的作弊层,不再堵。

### `TickInfo` 携带禁用状态

```swift
public var skipsExhausted: Bool   // true = 已达连续上限,暂停与跳过均不可用
```

**不给默认值**:全仓 `TickInfo(` 只有一个构造点(`tickInfo(now:)`),而本设计本就要改它。给默认值不带来任何兼容性收益,只会让将来漏填该字段的构造点静默取到 `false`(= 放行),失去编译期保护。

**无需预测式判断**:跳过的计数点在工作 `deadline` 而非 `now`,菜单据 `now` 的 `skipsExhausted` 置灰。两种失配都无害:

- **此刻已满、到点前清零**(长睡 ≥ `rest_minutes` 会在工作相位内清零)→ 菜单每 tick 重画,清零后下一拍(≤ 1 秒)即恢复可点,最多短暂多灰一格。
- **此刻未满、到点前因暂停而满** → 由决策 7 兜住:消费点重查 `skipsExhausted`,已满则作废勾选、落回正常路径。

菜单只是提示;`pause()` 的相位+额度守卫与 `advancePastWorkDeadline` 的消费点重查才是真防线,故 UI 陈旧既不会误计数也不会误放行。

> 早先版本在此处的论证是「`consecutiveSkips` 在工作相位内只增不减」——**该不变量为假**:`systemDidWake` 的长睡分支就在 `.working`/`.warning` 相位内清零。结论仍成立,但依据是「菜单每拍重画 + 真防线在核心」,与单调性无关。

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

**清零与 `+1`**(逐行覆盖「清零条件」表)

- 休息自然走完 → 清零
- `unlock` 未到点 + `require_full_rest = on` → **`+1`**(不是「不清零」——计数由 0 变 1)
- `unlock` 未到点 + `require_full_rest = off` → 清零
- **`unlock` 在 rest deadline 之后调用(`now >= deadline`)+ `require_full_rest = on` → 清零**(覆盖 `restWasFull: now >= deadline` 的 true 分支;构造:`breakNow(t0)` + rest=1min,`unlock(after(61))`)
- `systemDidWake` 休息已到点 → 清零(不论 `require_full_rest`)
- `systemDidWake` 休息未到点 + 短离开 + `wake_ends_rest = on` + `require_full_rest = on` → **`+1`**
- **`systemDidWake` 休息未到点 + 离开 ≥ `rest_minutes` + `wake_ends_rest = on` + `require_full_rest = on` → 清零**(钉死 `sleptFor` 判据,即「离开 22 分钟不该被罚」)
- `systemDidWake` 休息未到点 + `wake_ends_rest = on` + `require_full_rest = off` → 清零
- **`systemDidWake` 休息未到点 + `wake_ends_rest = off` → 相位仍是 `.resting`,计数**不变**(既不清零也不 `+1`;该分支根本不调 `endRest`)
- **连掐 `max` 次不完整休息后 `pause` 返回 `false`**(钉死决策 9 真的堵住了那条路)
- `systemDidWake` 工作中长睡 ≥ `rest_minutes` → 清零
- `systemDidWake` 工作中短睡 → 不清零、不消耗 armed skip
- **`systemDidWake` 在 `.paused` 相位 + 长睡 ≥ `rest_minutes` → 清零,且暂停 `deadline` 不变**(钉死清零提到 `switch` 之前)
- **`systemDidWake` 在 `.paused` 相位 + 短睡 → 不清零,暂停 `deadline` 不变**

**`reload` 回归**(堵一键免费跳过)

- **`reload` 只改 `message` → `deadline` 不变**(`tick(now: after(60))` 仍进 `.warning`)
- **`.warning` 中 `reload` → 相位仍是 `.warning`,预警到点照常进 `.resting`**
- `reload` 不清零计数

**回归**

- 既有回调顺序不变:`onPhaseChange(.working)` 先于 `onRestEnded`(现有 `testRestEndReasonFiresAfterPhaseChange` 覆盖 `endRest` 重构)
- `TickInfo.skipsExhausted` 正确上报

### `Tests/RestEyesCoreTests/ConfigTests.swift`(增补)

- 两个新键解析、越界回退、默认值(`maxConsecutiveSkips == 2` / `requireFullRest == true`)
- `require_full_rest` 的 `on` / `off` / 非法值
- **`parse("max_consecutive_skips = 0")` → `0`**。「风险与取舍」把 `= 0` 作为老用户恢复旧行为的唯一出口,而 `BreakSchedulerTests` 里那条「`0` 时永不拒绝」是直接给 Swift 字段赋值、**绕过了 parse**。若 `(0...100)` 写成 `(1...100)`,`0` 会被当非法值回退成 `2`,出口失效而无人发现。
- **`defaultFileContent` 里两个新键的键名真的能被 parse 认出**。

  不能依赖 `testDefaultFileContentRoundTrips`:它是 `XCTAssertEqual(Config.parse(Config.defaultFileContent), Config())`,而新键的文件值(`2` / `on`)**恰好等于 Swift 侧默认值**——漏加行、键名在文件里拼错、或 `parse` 的 `case` 标签拼错(命中 `default: continue`),它统统照样绿。

  也**不能**用 `XCTAssertTrue(Config.defaultFileContent.contains("max_consecutive_skips"))`:它根本不调 parser,发现不了 `case` 标签那一侧拼错。

  可行写法——把文件里的值替换成非默认值再 parse,两侧键名任一拼错都会让替换落空或解析失败,断言随即失败:

  ```swift
  func testDefaultFileContentDeclaresNewKeys() {
      let text = Config.defaultFileContent
          .replacingOccurrences(of: "max_consecutive_skips = 2", with: "max_consecutive_skips = 7")
          .replacingOccurrences(of: "require_full_rest = on", with: "require_full_rest = off")
      let c = Config.parse(text)
      XCTAssertEqual(c.maxConsecutiveSkips, 7)   // 文件里键名拼错 → 替换不命中 → 仍为 2 → 失败
      XCTAssertFalse(c.requireFullRest)          // parse 的 case 拼错 → 取不到 off → 仍为 true → 失败
  }
  ```

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
- **计数满时点暂停 → 合盖过夜 → 回来** → 计数已清零,两项可点。
- **休息刚开始就合盖几秒再打开**(默认 `wake_ends_rest = on`)→ 休息结束、回到工作,但**计数 `+1`**;重复到上限后暂停与跳过双双置灰。(这是决策 9 要堵的路。)
- **休息中「重新加载配置」**、**预警中「重新加载配置」** → 休息/预警**不被取消**(堵一键免费跳过)。
- 退出并重开 RestEyes → 计数清零(已知取舍)。

---

## 风险与取舍

- **纯内存态 = 重启即清零**(用户明确选择)。想绕过限制的人退出重开 RestEyes 即可,限制的定位是**防手滑、防惯性**,不是防自己作弊。换来的收益是删掉整条持久化链路:无文件读写、无序列化、无损坏/权限失败的降级路径、无双实例并发问题。
- **升级即被限**:默认 `max_consecutive_skips = 2` 对老用户是**静默的行为变更**(`config.txt` 已存在时 `Config.load` 不会重写,新键缺失即取默认值)。README 须醒目说明,`max_consecutive_skips = 0` 可恢复旧行为。
- **`require_full_rest = on` 默认值是第二处行为变更**:休息中点「解锁」不再清零计数,反而 `+1`。这正是防护意图,不需要者配 `off`。
- **决策 9 的误伤面**:`wake_ends_rest = on`(默认)下,休息未跑满时被系统自动熄屏/屏保打断、且离开时长 < `rest_minutes`,回来会记 `+1`——用户并未主动逃避。取舍理由:① 默认熄屏/屏保延时(十几分钟)远大于默认 `rest_minutes`(3 分钟),该组合在实践中罕见;② 不这么做就重开「合盖 6 秒」那条零成本无限逃避路径,功能失效;③ 不接受者可配 `wake_ends_rest = off`(休息跨越唤醒保留)或 `require_full_rest = off`。备选方案(不送完整 `work_minutes`,改记「休息欠账」让下个 deadline 立即到点)需多一个状态位,复杂度不划算。
- **计数可短暂超过上限**:2 次暂停 + 1 次掐断休息 = 3 > `max = 2`。`skipsExhausted` 用 `>=` 判定,行为正确(仍是禁用),只是「上限」不是硬顶。这是「生效时才计数」与「掐断也计数」叠加的自然结果。
- **首次改动 `BreakScheduler`**:此前三份设计均以「不动状态机」为约束。此处必须打破——跳过的消耗点在核心内部,而 CI-only 要求判断逻辑可单测。改动面:`pause()` 签名、`reload()` 条件、两个私有方法(`endRest` / `advancePastWorkDeadline`)、`systemDidWake()` 的清零与 `.resting` 分支、一个计数器、`TickInfo` 一个字段。
- **`pause()` 签名变更**:`Void → @discardableResult Bool`。现有调用点(`main.swift` 的 `onPauseToggle`、单测)无需改写即可编译。
- **`reload()` 语义收紧**:只在 `.working` 相位且 `work_minutes` 真的变了时才重开计时。这修掉一条既有的一键免费跳过路径,副带让「改 `message` 不再重置工作倒计时」。既有三条 reload 单测仍绿。
- **不限制总量**:「暂停 1 小时 → 老实休息 3 分钟 → 再暂停 1 小时」可以无限重复,一天下来大部分时间处于暂停中。这是模型的**有意选择**(决策 2):既然每次之间都完整休息了,护眼目的已达成。想额外卡总量需要另一套机制,本设计不做。
- **达上限时勾选的跳过被静默作废**:用户的意图消失,仅在菜单标题体现。备选(保留勾选待计数清零后自动生效)被否——休息完之后突然跳过一次休息更意外。
- **ESC×10 后门与解锁按钮同路**:二者同经 `unlock()`,故 `require_full_rest = on` 且休息未到点时都记 `+1`。ESC×10 仍**永不被拒绝**(能强制结束卡住的遮罩),只是要花额度。

## 代码触点

- **`Sources/RestEyesCore/BreakScheduler.swift`**:加 `consecutiveSkips` 计数器与 `skipsExhausted` 计算属性;`pause()` 返回 `Bool` 并内查上限;新增 `endRest(now:reason:restWasFull:)` 收口三个休息结束点(含没跑满 `+1`);`tick()` 的 `case .working, .warning` 抽为 `advancePastWorkDeadline(now:)` 并接入跳过计数与拒绝;`systemDidWake()` 把「离开够久 → 清零」提到 `switch` 之前、`.resting` 分支按 `now >= deadline` / `sleptFor` 判 `restWasFull`;`reload()` 加「相位与 `work_minutes` 双重条件」;`TickInfo` 加 `skipsExhausted`(无默认值)。
- **`Sources/RestEyesCore/Config.swift`**:新增 `maxConsecutiveSkips` / `requireFullRest` 字段、两个 `case` 解析、`defaultFileContent` 增两行。
- **`Sources/RestEyes/StatusItem.swift`**:`update` 签名增 `skipsExhausted`;`pauseItem` / `skipItem` 的标题与 `isEnabled` 按上述规则重算。
- **`Sources/RestEyes/main.swift`**:两处。① `onTick` 内 `statusItem.update(...)` 增传 `skipsExhausted`;② `reconcileIfBack()` 的 `case .paused` 由 `break` 改为调 `systemDidWake(sleptFor: awayFor, now:)`,让暂停中的长时间离开也能清零计数。
- **`Tests/RestEyesCoreTests/BreakSchedulerTests.swift`**、**`ConfigTests.swift`**:见「测试与验收」。
- **`README.md`**:配置表增两键 + 已知边界(升级即被限、`require_full_rest` 行为变更、重启清零、不限总量)+ 手动验收清单。
- **不改**:`Format.swift`、`OverlayController.swift`、`ScreenLocker.swift`、`LoginItem.swift`。**不新增类型或文件。**
