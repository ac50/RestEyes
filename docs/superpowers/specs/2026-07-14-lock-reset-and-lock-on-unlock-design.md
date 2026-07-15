# RestEyes 设计:离开(锁屏/熄屏/屏保)不冻结照常跑、够久才重置 + 结束锁屏不闪桌面 + 点击解锁后锁屏

日期:2026-07-14
状态:已确认

关联:在 [2026-07-12-away-detection-and-lock-no-flash-design.md](2026-07-12-away-detection-and-lock-no-flash-design.md) 之上做三处修改。**本设计用一套更简单的模型取代 2026-07-12 的「缺席冻结 + 轮询 + 看门狗」离开检测**(那套为补各种漏收通知一版版叠加,复杂度失控)。**核心约束不变**:不改动 `BreakScheduler` 纯逻辑状态机、不改动 `ScreenLocker`;全部改动落在 AppKit 胶水层(`main.swift`)与 `Config`。

## 背景:三个问题

1. **纯锁屏(未合盖)回来不重置工作倒计时**:工作中仅锁屏(不合盖)、长时间离开后解锁回来,工作倒计时没有重置为全新周期。
2. **休息自然结束→锁屏时闪一下桌面**:`lock_after_rest = on` 下休息走完,现象是「黑遮罩消失 → 露一下桌面 → 才出现锁屏界面」。
3. **(新)点击解锁后直接进入系统锁屏**:休息中点「解锁」当前直接回桌面、无需任何密码;希望新增开关,点解锁后走系统锁屏,用系统自带锁屏当密码门(RestEyes 不自管密码),防止离开时被无密码一键解锁。

> 前提(已确认):用户设了开机密码,锁屏会弹出需输密码的锁屏界面,故 ②③ 的「遮罩直连锁屏」成立。

---

## 问题①:离开(锁屏/熄屏/屏保)一律照常跑、够久才重置

### 为什么推翻旧模型

旧模型是「离开期间**冻结**计时,回来对账」。为兜住偶发漏收的唤醒/解锁通知,又叠了「缺席轮询」和「1 小时看门狗」——轮询依赖半私有键 `CGSSessionScreenIsLocked`,而该键对后台(`.accessory`)应用不可靠:锁屏时误返 `false` → 轮询约 3 秒就把锁屏缺席**提前解冻** → 调度器在锁屏背后乱跑、解锁时又不再对账 → **这正是纯锁屏不重置的根因**。

根本问题在于「冻结」这个选择:一旦冻结,漏收解锁通知就会**永久卡死**,才被迫引入看门狗那套复杂度。换成**不冻结**,这些复杂度整体消失。

### 新模型:不冻结、照常跑、够久才重置

**离开信号(三者合并)**:锁屏、熄屏、屏保。任一开始且此前不在离开态 → 记 `awayBeganAt = now`;三者全部结束(**解锁 且 亮屏 且 屏保停** = 真回来)→ 收口对账。用三个标记 `isScreenLocked`/`isDisplayAsleep`/`isScreensaverActive` 聚合,`isAway = 三者之一为真`。

**计时**:心跳**永远正常 `tick`,绝不冻结**。系统真挂起(睡眠/合盖:CPU 停、时钟跳)仍由既有**时钟跳变**分支 `systemDidWake(gap)` 对账(原样保留)。

**离开期间(`isAway == true`)—— 抑制休息,但计时照走**:
- 调度器内部相位照常循环(work→rest→work…),但胶水层**不新显示休息遮罩、也不显示「N 秒后休息」预警浮窗**(锁屏背后画遮罩无意义);已在显示中的遮罩(离开前就进了休息)不主动撤,任其被锁屏界面盖住,到点/回来时再撤。
- **不触发 `lock_after_rest`**:锁屏背后对已锁的屏再锁一次无意义。

**回来时(三标记全清)**,算 `awayFor = now − awayBeganAt`,**一律收口到工作态**:
- **工作/预警相位**:`awayFor ≥ rest_minutes` → `systemDidWake(awayFor)`(落到 `startWork` → 全新工作);`< rest_minutes` → **什么都不做**(计时器本就照常走着,不补偿)。
- **休息相位**(离开期间进了休息):`systemDidWake(awayFor)` —— `wake_ends_rest = on`(默认)→ 结束休息回工作(`onRestEnded(.wake)` → 撤遮罩);`= off` 且休息未到点 → 休息继续,此时把(离开期间被抑制的)遮罩**显示出来**(与该开关「休息跨越唤醒保留」语义一致)。
- **暂停相位**:不动。
- 对账后清 `awayBeganAt`。

**由此确定的两个行为**(已与用户确认):
- 「工作快到点时锁一下屏、几分钟后回来」→ `awayFor < rest_minutes` → 跳过那次本该到的休息,直接回工作。**这是预期效果**(锁屏 = 已把视线移开屏幕,算休息)。
- **永远不会一解锁就撞进休息**(默认 `wake_ends_rest = on` 下)。

### 为什么不冻结 / 能删看门狗

计时器一直在走,就不存在「被冻结后永久卡死」的状态:即便解锁通知偶发漏收,最坏也只是「漏掉一次重置」——计时器继续正常跑,下个周期自愈,而非停摆。因此**看门狗、缺席轮询、半私有键、冻结分支全部删除**,不再需要任何兜底解冻。

### 删除清单(全在 `main.swift`)

- 看门狗 `absenceForceClearCeiling(3600)`、轮询去抖 `absencePollDebounce`、心跳里的「缺席冻结 + 轮询」分支。
- `userIsPresent()`、`screenIsLockedNow()` 及其 `CGSessionCopyCurrentDictionary` / `CGSSessionScreenIsLocked` 读取(半私有键,全仓唯一使用点,删后无残留引用)。

**保留**:三个 away 标记(仅用于聚合判断离开/回来)+ `awayBeganAt` 时间戳 + 时钟跳变对账 + 六个离开通知观察者(锁屏/解锁、熄屏/亮屏、屏保启/停)。

### 时序示例

```
纯锁屏离开 30 分钟(rest_minutes=3):
  screenIsLocked → isScreenLocked=true, awayBeganAt=now
  锁屏期间:心跳照常 tick;内部若到点进休息 → 胶水层不画遮罩、不锁屏
  screenIsUnlocked → 三标记全清 → awayFor=30min ≥ 3 → systemDidWake → startWork → 全新工作

短锁屏 1 分钟(工作快到点):
  screenIsLocked → 记 awayBeganAt
  锁屏期间到点进休息 → 遮罩被抑制(不画)
  screenIsUnlocked → awayFor=1min < 3 → 休息相位:systemDidWake(wake_ends_rest=on)→ 结束休息回工作
  结果:跳过这次休息,直接回工作(预期)
```

---

## 问题②:休息自然结束→锁屏,中间不露桌面

### 根因

2026-07-12 把撤黑窗延迟到锁屏后,但撤窗触发之一是 **2.5s 无条件兜底**(`main.swift` 现 `lockConfirmFallback`),它撤窗前**不检查是否已锁**:锁屏慢/通知晚到时,2.5s 到点就在桌面还露着时撤了黑窗——正是「遮罩消失 → 露桌面 → 锁屏」。

### 方案:通知确认 + 延迟撤窗 + 5s 兜底(用户选定「延迟撤窗」;不读半私有键)

**仅在「用户在场时休息自然结束且 `lock_after_rest = on`」这条路才进入**(离开期间休息结束不锁屏,见问题①)。`onRestEnded(.completed)` 且 `!isAway && lockAfterRest` 时:`detachRestInteraction()` + `ScreenLocker.lock()` + 置 `pendingRestWindowRemoval`,然后:

1. **通知确认 + 延迟撤窗(快路)**:`com.apple.screenIsLocked` 观察者收到锁屏信号后,不立即撤窗,而是再等约 **0.4s** 合成缓冲(让锁屏界面完全画完)才 `removeRestWindows()`。自发锁屏通知快且可靠;缓冲消除「通知在锁屏界面合成完成前到达」那一帧竞态。黑窗恒在锁屏界面下方,晚撤只会更安全、绝不可见。
2. **兜底(慢路)**:原 2.5s 无条件兜底改为约 **5s** 硬上限。常态走快路(几百毫秒内撤),兜底几乎不触发;仅当 5s 内始终没收到锁屏通知才撤——此时若已锁上(通知偶发漏收)撤窗在锁屏界面下方不可见,若真没锁上(无密码机器)才短暂露桌面,属真实无法锁屏的降级。

> 不轮询半私有键来「确认锁屏」:那个键正是问题①的不可靠根源;macOS 对后台应用也没有可靠的公开「是否锁屏」查询。故以「自发锁屏必发的 `com.apple.screenIsLocked` 通知 + 合成缓冲」为准、5s 上限兜底。

> 注:自发锁屏也会令 `isScreenLocked=true`、记 `awayBeganAt`(问题① 的离开追踪)——正确,你此刻确实在锁屏界面;稍后解锁 `awayFor` 很短 → 不重置(且此时已在工作态),不产生副作用。

---

## 问题③(新):`lock_on_unlock` —— 点击解锁后进入系统锁屏

### 需求与取舍

开启后,休息中**手动解锁**不再直接回桌面,而是触发系统锁屏,须输开机密码才回桌面。**取消**原「App 内密码验证输入框」方案(免明文密码、免输入框焦点/吞键难题)。

- **默认开**(用户选定):安全优先。与默认开的 `lock_after_rest` 叠加后,**在场时每次退出休息(自然走完或手动解锁)都会落到系统锁屏**、需输密码——这正是防护意图,属预期。不需要者配 `lock_on_unlock = off` 恢复一键解锁。
- **ESC×10 应急后门一并走锁屏**:若 ESC×10 能绕过锁屏直接回桌面,狂按 ESC 即可绕过防护、功能失效。故开启此项后 ESC×10 也落系统锁屏。OS 密码永远是入口,不会锁死;ESC×10 仍能强制结束卡住的遮罩,只是落在锁屏界面。

### 方案:复用问题②的锁屏撤窗路

`onRestEnded(reason)` 分流(注意 `.unlocked` 只可能在**在场**时发生——解锁按钮/ESC×10 都要遮罩显示着才点得到,故其天然 `!isAway`):

```
if !isAway && reason == .completed && lockAfterRest { 走②的「延迟锁屏 + 通知确认撤窗」路 }
else if !isAway && reason == .unlocked && lockOnUnlock { 同一条锁屏撤窗路 }
else { overlay.hideRest() }
```

- `.unlocked` 涵盖解锁按钮与 ESC×10(二者同经 `onUnlockRequested → scheduler.unlock → onRestEnded(.unlocked)`),开关一处即同时作用。
- `.wake`(问题① 回来对账时触发)与「离开期间 `.completed`」都落到 `else → hideRest()`,**不锁屏**。
- `BreakScheduler` 不变:`.unlocked` 仍表示手动解锁;锁不锁完全由胶水层依 `lock_on_unlock` 决策。

---

## 配置变更

`Config` 仅新增一项:

```
public var lockOnUnlock: Bool = true
```

- 解析新增 `case "lock_on_unlock"`(on/off,非法值回退默认 on),与 `lock_after_rest` 同风格。
- `defaultFileContent` 增行:
  `lock_on_unlock = on    # 点击「解锁」或 ESC×10 后进入系统锁屏,需输开机密码才回桌面(on/off)`
- 默认值 `true` 与 defaultFileContent 的 `on` 一致,`testDefaultFileContentRoundTrips` 仍成立。

**问题① 不新增配置**:重置门槛复用现有 `rest_minutes`。其余键、语义、默认值全部不变。

## 不改动的部分

- **`BreakScheduler`** 纯逻辑状态机完全不动(相位、`tick`、`systemDidWake`、`onRestEnded` 三原因不变;问题① 的「重置」复用 `systemDidWake(awayFor)`,只在需要重置时调,不改其逻辑)。
- **`ScreenLocker`** 不动。
- **`OverlayController`** 不动:问题① 的「抑制/显示」由胶水层决定**是否调用** `showRest`/`showWarning`,②③ 复用现有 `detachRestInteraction()` / `removeRestWindows()` 两段式,均无需改 Overlay。

## 测试与验收

改动集中在 `main.swift` 胶水层 + `Config`;`BreakScheduler` 纯逻辑不变,现有单测照旧通过。新增:

- `ConfigTests`:`lock_on_unlock` 解析 on/off/缺省/非法值;`defaultFileContent` 往返。
- 通知订阅、窗口撤窗时序、系统锁屏依赖真实 AppKit/系统环境,不做单测;沿用「本地不编译、以 GitHub Actions 为准」。

README 手动验收清单更新:

- **①·纯锁屏重置**:工作中仅锁屏(不合盖)离开 ≥ `rest_minutes` 再解锁 → 全新工作;< `rest_minutes` → 接着原工作,**不会一解锁就进休息**。
- **①·锁屏不弹休息**:锁屏期间即使内部到点,也**不在锁屏背后弹遮罩、不额外锁屏**;熄屏/启屏保同理。
- **①·休眠**:合盖/睡眠 ≥ `rest_minutes` 唤醒解锁 → 全新工作。
- **②**:在场时 `lock_after_rest = on` 休息自然走完 → 黑遮罩**直接切锁屏,中途不露桌面**。
- **③**:`lock_on_unlock = on`(默认)休息中点「解锁」/ESC×10 → 落系统锁屏、需输密码;`off` → 一键回桌面。

## 风险与取舍

- **不再依赖半私有键 / 看门狗 / 轮询 / 冻结**:模型大幅简化。代价:漏收解锁通知时不再有主动兜底解冻——但因**不冻结**,后果仅是「漏掉一次重置」(计时器照常跑、自愈),非停摆,可接受。
- **短锁屏跳过本该到的休息**:预期行为(锁屏=已移开视线)。
- **锁屏背后照常跑**:长锁屏期间调度器内部会空转 work/rest 循环(不画、不锁),纯内部无副作用;回来一律收口工作态。
- **② 合成缓冲 0.4s / 兜底 5s** 为经验常数,真机可微调;无密码机器 `lock_after_rest` 降级为 5s 后撤窗(比原 2.5s 多几秒黑窗;用户有密码,不受影响)。
- **`lock_on_unlock` 默认开是行为变更**:升级后在场手动解锁都先过系统锁屏,叠加 `lock_after_rest` 后每次退出休息都需输密码——属预期,文档醒目说明。
- **ESC×10 语义变化**:开 `lock_on_unlock` 后落锁屏而非桌面;防绕过的必要取舍,OS 密码保证不锁死。

## 代码触点

- **`Sources/RestEyes/main.swift`**:
  - `startTicking()` 心跳:**删除**缺席冻结+轮询分支,只留时钟跳变对账 + 正常 `tick`;删 `absenceForceClearCeiling` / `absencePollDebounce`。
  - **删除** `userIsPresent()`、`screenIsLockedNow()`(及 `CGSessionCopyCurrentDictionary` / `CGSSessionScreenIsLocked`)。
  - 六个离开通知观察者:begin → 置标记 + `noteAwayBegan()`;end → 清标记 + `reconcileIfBack()`。
  - `noteAwayBegan()`:首个离开置 `awayBeganAt`。
  - `reconcileIfBack()`(原 `endAbsenceIfPresent`):三标记全清才对账 —— 按「回来时」规则(工作相位 `awayFor≥rest` 才 `systemDidWake` 重置、否则不动;休息相位 `systemDidWake` 并按 `wake_ends_rest` 决定回工作或显示遮罩)→ 清 `awayBeganAt`。
  - 加 `isAway` 便捷属性(三标记之一)。
  - `wire()`:`onPhaseChange(.resting)` / `.warning` 与 `onTick` 的休息/预警显示 → 以 `!isAway` 为条件(离开期间抑制);`onRestEnded` → 分流并上 `!isAway` 前提,并入 `.unlocked && lockOnUnlock`(问题③),`.completed && lockAfterRest` 走延迟锁屏路(问题②)。
  - 延迟锁屏撤窗:锁屏通知 + 0.4s 合成缓冲 + 5s 兜底上限,替换 2.5s 无条件兜底(问题②)。
- **`Sources/RestEyesCore/Config.swift`**:新增 `lockOnUnlock` 字段、`lock_on_unlock` 解析、`defaultFileContent` 增行。
- **`Tests/RestEyesCoreTests/ConfigTests.swift`**:`lock_on_unlock` 解析与往返用例。
- **`README.md`**:配置表 + 已知边界 + 手动验收清单更新。
- **不改**:`BreakScheduler.swift`、`ScreenLocker.swift`、`OverlayController.swift`、`Format.swift`、`LoginItem.swift`、`StatusItem.swift`。
