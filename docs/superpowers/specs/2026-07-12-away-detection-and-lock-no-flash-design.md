# RestEyes 设计:离开检测增强 + 休息结束锁屏不闪桌面

日期:2026-07-12
状态:已确认

关联:本设计在 [2026-07-10-resteyes-design.md](2026-07-10-resteyes-design.md) 的行为模型上做两处增强。核心约束——**不改动 `BreakScheduler` 纯逻辑状态机,不改动 `systemDidWake` 的相位判定,不新增任何配置项**;全部改动落在 AppKit 胶水层(`main.swift` / `OverlayController.swift`)。

## 背景与问题

本设计解决两个用户报告的问题:

1. **休息结束锁屏时闪一下桌面**:当 `lock_after_rest = on`、休息时间自然走完时,当前顺序是「撤掉黑遮罩 → 露出桌面 → 系统锁屏界面弹出」。锁屏是异步的,中间那一瞬桌面(工作内容)被看到。期望:黑遮罩直接切到锁屏界面,全程不露出任何工作内容。

2. **长时间离开回来仍进入 / 停留在休息**:用户长时间锁屏、熄屏或合盖后解锁回来,期望「一律直接进入工作状态」——长时间离开等同于眼睛已休息,不该再让他休息,也不该把离开期间「本应到点」的休息补给他。用户实测锁屏、**以及合盖**都可能出现回来后卡在休息。

关键结论(详见需求 1 分析):**返回时的相位判定逻辑本身是对的**(离开 ≥ `rest_minutes` 即重置为全新工作,已实现);真正的缺口在**「用户已离开 / 已回来」这两个事件的检测不够可靠**——尤其是唤醒 / 解锁通知偶发漏收,导致缺席状态卡死、计时永久冻结、遮罩滞留。因此需求 1 的改动集中在**检测可靠性**,不动状态机。

## 需求 2:休息自然结束 → 锁屏,中间不露桌面

### 根因

休息自然结束的一次 `tick` 内,回调按此顺序触发:

1. `startWork()` → `transition(.working)` → `onPhaseChange(.working)`,当前实现里在此调用 `overlay.hideRest()`——**撤掉黑遮罩,桌面露出**。
2. 紧接着 `onRestEnded(.completed)`,当前实现里才调用 `ScreenLocker.lock()`。

锁屏界面是系统异步弹出的,在第 1 步撤遮罩到第 2 步锁屏界面盖上之间,桌面工作内容被短暂看到。

### 方案

把「撤休息遮罩」的职责从 `onPhaseChange(.working)` **迁移到 `onRestEnded`**,并让「要锁屏」这一路延迟撤窗到锁屏确认之后。

**1. 迁移撤窗职责(不变量)。** 退出 `resting` 只有三条路——`completed` / `unlocked` / `wake`——每条都必然触发 `onRestEnded`(见现有 `BreakScheduler`:`tick` 完成、`unlock()`、`systemDidWake` 三处)。因此 `onRestEnded` 是撤遮罩的唯一收口点。`onPhaseChange(.working)` 不再碰遮罩(仅保留 `hideWarning()` 与 `reloadConfigIfChanged()`)。这条「resting 的退出必经 onRestEnded」不变量以注释写入代码,后续新增退出路径必须遵守。

**2. `onRestEnded(reason)` 分流:**

| 情况 | 处理 |
|---|---|
| `completed` 且 `lock_after_rest = on` | **延迟锁屏路**:遮罩黑窗保持不撤;先停掉遮罩的交互部件(每秒抢焦点定时器、吞键盘监听、屏幕参数监听,并恢复 `presentationOptions`,让用户能输密码);调 `ScreenLocker.lock()`;置「待锁屏确认后撤窗」标记并启动兜底计时器。 |
| `completed` 且 `lock_after_rest = off` | 立即 `hideRest()`(无锁屏,无闪桌面之虞)。 |
| `unlocked` / `wake` | 立即 `hideRest()`(设计上刚解锁不再锁回去,照旧)。 |

**3. 锁屏确认后撤窗。** 现有的 `com.apple.screenIsLocked` 观察者里,若「待锁屏确认后撤窗」标记为真,则撤掉黑窗并清标记、取消兜底计时器。此时系统锁屏界面已盖在黑遮罩之上,撤窗发生在其下方,不可见。

**4. 兜底。** 调 `lock()` 后启动约 **2.5 秒**一次性计时器;若届时仍未收到 `screenIsLocked`(未设开机密码、锁屏失败等)→ 直接撤窗,避免遮罩永久滞留。可能露出极短桌面,属罕见降级。

### 时序(延迟锁屏路)

```
tick(resting, 到点)
  ├─ startWork → onPhaseChange(.working)   # 只 hideWarning + reload,不撤遮罩
  └─ onRestEnded(.completed) + lock_after_rest=on
        ├─ 停交互(定时器/键盘/参数监听),恢复 presentationOptions,黑窗仍在
        ├─ ScreenLocker.lock()
        ├─ pendingHideAfterLock = true;启动 2.5s 兜底
        │
   [系统锁屏界面弹出,盖在黑窗之上]
        │
  screenIsLocked 通知
        └─ pendingHideAfterLock → 撤黑窗 + 清标记 + 取消兜底
```

视觉结果:**黑遮罩 → 锁屏界面**,中间不出现桌面。

### 遮罩两段式拆分(OverlayController)

当前 `hideRest()` 一步做完「停交互 + 撤窗 + 恢复 presentationOptions」。延迟锁屏路需要把它拆成两段:

- **停交互(保留黑窗)**:invalidate 抢焦点定时器、移除键盘监听与屏幕参数监听、恢复 `presentationOptions`;黑窗仍在屏上。目的:锁屏前就停止抢焦点和吞键,让用户能在锁屏界面输入密码,同时画面仍是纯黑。
- **撤黑窗**:`orderOut` 全部黑窗、清空数组、`isShieldActive = false`。

`hideRest()` = 两段顺序执行(等价现状);延迟锁屏路 = 先「停交互」,锁屏确认后再「撤黑窗」。

## 需求 1:长时间离开(锁屏 / 熄屏 / 合盖)回来一律进入工作

### 现状:冻结 + 对账(不是「停止程序」)

程序**不退出**。当前模型是「缺席期间冻结计时,回来时按离开时长对账」:

- **缺席开始**:收到 `willSleep` 或 `com.apple.screenIsLocked` → 置标记 + 记 `absenceBeganAt`;主心跳见 `absenceBeganAt != nil` 即**不再推进状态机**(真正系统睡眠时 CPU 本就停转)。
- **缺席结束**:收到 `didWake` / `com.apple.screenIsUnlocked` → 清对应标记;**仅当睡眠与锁屏标记全部清零**,才计算 `sleptFor = now − absenceBeganAt` 并调 `systemDidWake(sleptFor)`。
- **对账**(`systemDidWake`,本设计**不改**):
  - `working` / `warning`:`sleptFor ≥ rest_minutes` → 全新工作;否则 `deadline += sleptFor`(接着走没走完的工作)。
  - `resting`:离开期间休息已到点(`now ≥ deadline`)或 `wake_ends_rest = on` → 回工作(原因 `.wake`,不锁屏);否则遮罩按墙钟继续。
  - `paused`:不变。

**结论**:只要缺席被正确「开始并结束」,对账逻辑已满足「长离开 → 全新工作、短离开 → 续走工作、都不进休息」。所以需求 1 不改对账,只补检测。

### 缺口

**缺口 A —— 开始漏检(熄屏 / 屏保没有通知)。** 纯显示器熄屏或屏保启动、但未触发系统锁屏时,现有代码收不到任何「缺席开始」信号,主心跳不冻结,状态机一路跑进 `warning` → `resting`。用户回来撞见休息遮罩,且因从未记录缺席,`systemDidWake` 不会被调用来纠正。

**缺口 B —— 结束漏检(唤醒 / 解锁通知漏收 → 卡死)。** 这是**合盖也会卡在休息**的根因。`didWake` 或 `screenIsUnlocked` 在跨睡眠 / 唤醒时偶发漏收,一旦漏收:对应标记永远清不掉 → `endAbsenceIfPresent` 的守卫永远不通过 → 缺席永不结束 → 计时**一直冻结**、合盖前的休息遮罩**一直滞留**,直到 1 小时看门狗才强制解冻。「多监听几类事件」只能补缺口 A,补不了缺口 B。

### 方案 A:拓宽「缺席开始」通知(补缺口 A)

在现有 `willSleep` / `screenIsLocked` 之外,新增两对通知,汇入**同一套**缺席标记聚合:

- `NSWorkspace.screensDidSleepNotification` / `screensDidWakeNotification`(显示器熄屏 / 亮屏)——直接补上原设计文档所述「纯熄屏无通知」缺口。
- `com.apple.screensaver.didstart` / `com.apple.screensaver.didstop`(经 `DistributedNotificationCenter`,与现有锁屏通知同源)——屏保启停。

熄屏通知是主力;屏保通知在个别系统上未必稳定,作为补充网。均为标准通知,**不需要任何 TCC 权限**。

### 方案 B:「缺席结束」轮询兜底(补缺口 B)

在主心跳的**冻结分支**(即已处于缺席、`absenceBeganAt != nil` 时)每秒顺带轮询真实状态,发现用户其实已回来就立即结束缺席——**哪怕唤醒 / 解锁通知漏收**:

```
if absenceBeganAt != nil:
    awayFor = now − absenceBeganAt
    if awayFor ≥ 看门狗上限(3600s):                 # 现有兜底
        强制结束缺席(见下)
    else if awayFor ≥ 去抖阈值(约 3s) 且 用户已在场:  # 新增
        强制结束缺席(见下)
    return    # 仍冻结,不推进状态机
```

- **「用户已在场」判定**:`屏幕未锁定 && 显示器未睡眠`。
  - 显示器睡眠:公开 API `CGDisplayIsAsleep(CGMainDisplayID())`。
  - 屏幕锁定:读 `CGSessionCopyCurrentDictionary()` 的 `CGSSessionScreenIsLocked` 键(半私有键,**无需 TCC**;与项目已采用的私有锁屏 API `SACLockScreenImmediate` 属同一取舍)。**备选**:若不引入半私有键,可改用完全公开的 `CGEventSourceSecondsSinceLastEventType(.combinedSessionState, .anyInputEventType)`(距上次输入的空闲秒数)——空闲很小即视为用户回来;判定较间接、且对「在场但静止阅读」会等到用户动作才解冻,可接受。**本设计默认采用 `CGSession` 键**;此为唯一待复核的取舍点,复核时若倾向「零私有依赖」可切换为空闲时间备选,不影响其余设计。
- **去抖阈值 ~3s**:防止刚锁屏那一瞬会话锁定态尚未落定被误判为「在场」而立即解冻。对真实回来仅延迟数秒,无感。
- **强制结束缺席**:清零全部缺席标记(睡眠 / 锁屏 / 熄屏 / 屏保),置 `absenceBeganAt = nil`,以**实际 `awayFor`** 调 `systemDidWake(awayFor)`——与看门狗同一收口,只是时长用真实值而非上限。

轮询**只在已缺席(已冻结)时运行**,正常工作期零开销;因此这是介于「只加通知」与「每秒全程轮询」之间、**只针对结束漏检的定向补丁**,不是被否掉的全程轮询方案。

### 门槛:复用 `rest_minutes`

「离开多久算已休息、回来重置为全新工作」的门槛沿用现有 `systemDidWake` 中的 `rest_minutes`,**不新增配置项**。数学上,`resting` 相位下只要离开 ≥ `rest_minutes` 必然已过休息终点,故复用后各相位行为自洽。

### 缺席标记聚合与看门狗

- 缺席标记从现有 `isAsleep` / `isScreenLocked` 扩为四个:`isAsleep` / `isScreenLocked` / `isDisplayAsleep` / `isScreensaverActive`。
- `noteAbsenceBegan()`:任一标记转真即调,首次置 `absenceBeganAt`。
- `endAbsenceIfPresent()`:守卫改为**四个标记全假**才结束缺席。
- 1 小时看门狗强制清零时,需一并复位全部四个标记。

## 不改动的部分

- **`BreakScheduler`**(纯逻辑状态机)完全不动:相位、`tick`、`systemDidWake`、`onRestEnded` 语义与三种原因(`completed` / `unlocked` / `wake`)一字不改。
- **配置**不动:不新增、不改名、不改默认值;`rest_minutes` / `lock_after_rest` / `wake_ends_rest` 语义保持。
- **`ScreenLocker`** 不动:仍是 `SACLockScreenImmediate` + `CGSession -suspend` 降级。
- **锁屏决策不变**:只有 `completed` 且 `lock_after_rest = on` 才锁屏;`unlocked` / `wake` 不锁。本设计只改「锁屏与撤遮罩的先后」,不改「是否锁屏」。

## 测试与验证

两处改动都在 AppKit 胶水层,`BreakScheduler` 纯逻辑不变,故**现有单元测试全部照旧通过,不新增逻辑测试**。通知订阅、窗口撤除时序、系统锁屏依赖真实 AppKit / 系统环境,不做单测。仍遵循项目「本地不编译、以 GitHub Actions 结果为准」的闭环。

README 手动验收清单新增:

- **需求 2**:`lock_after_rest = on` 下等休息自然走完 → 观察黑遮罩**直接切到锁屏界面,中途不露桌面**。另验 `lock_after_rest = off` 时休息结束正常撤遮罩露桌面(不锁)。
- **需求 1 · 开始漏检**:工作中让显示器熄屏(或启屏保)≥ `rest_minutes` 再唤醒 → 回到**全新工作**;< `rest_minutes` → 接着原工作。
- **需求 1 · 结束漏检**:合盖 / 锁屏离开较久再开盖解锁 → **数秒内**回到工作、休息遮罩不滞留(验证轮询兜底在唤醒通知漏收时仍能解冻)。
- **回归**:休息中手动解锁(按钮 / ESC×10)、`wake_ends_rest` 开关、多显示器遮罩等原有项不受影响。

## 风险与取舍

- **锁屏界面层级低于黑遮罩的极端机型**:理论上 loginwindow 恒在最上(设计文档亦记 SecurityAgent 认证框可高于 shielding level),风险极低;2.5s 兜底防止遮罩滞留。
- **熄屏即视为离开**:「读长文导致显示器自动熄屏」也会被算作离开,亮屏 ≥ `rest_minutes` 即算已休息 → 全新工作。这符合用户「离开就重置」的诉求,属预期行为,非缺陷。
- **屏保通知不稳**:个别系统上 `com.apple.screensaver.*` 未必可靠;熄屏通知为主力,且结束漏检有轮询兜底,整体不依赖屏保通知的可靠性。
- **`CGSSessionScreenIsLocked` 半私有键**:无 TCC、与项目既有私有 API 取舍一致;若系统改动导致取值不可用,轮询「在场」判定退化,仍有 1 小时看门狗兜底。备选公开空闲时间方案见需求 1。
- **~3s 去抖延迟**:真实回来后最多约 3 秒才解冻;换取避免锁屏瞬间误判,权衡可接受。
- **轮询开销**:仅在已缺席时每秒一次轻量系统查询,正常工作期不轮询,开销可忽略。

## 代码触点

- **`Sources/RestEyes/main.swift`(`AppDelegate`)**——主要改动:
  - `observeSleepAndLock()`:新增 `screensDidSleep/Wake` 与 `screensaver.didstart/didstop` 订阅;新增 `isDisplayAsleep` / `isScreensaverActive` 标记。
  - `endAbsenceIfPresent()`:守卫扩为四标记全假。
  - `startTicking()` 冻结分支:新增「缺席结束轮询兜底」(在场判定 + ~3s 去抖 + 实际时长对账);看门狗复位全部标记。
  - `wire()`:`onPhaseChange(.working)` 去掉撤遮罩(留 `hideWarning` + `reloadConfigIfChanged`);`onRestEnded` 改为分流(延迟锁屏路 / 立即撤遮罩);新增「待锁屏确认后撤窗」标记与 2.5s 兜底计时器;`screenIsLocked` 观察者内触发延迟撤窗。
  - 新增在场判定小工具(`CGDisplayIsAsleep` + `CGSessionCopyCurrentDictionary`,或备选空闲时间)。
- **`Sources/RestEyes/OverlayController.swift`**——把 `hideRest()` 拆为「停交互(保留黑窗)」+「撤黑窗」两段,供延迟锁屏路分两步调用;`hideRest()` 仍等价于两段顺序执行。
- **不改**:`Sources/RestEyesCore/BreakScheduler.swift`、`Config.swift`、`Format.swift`、`ScreenLocker.swift`、`StatusItem.swift`、`LoginItem.swift`。
