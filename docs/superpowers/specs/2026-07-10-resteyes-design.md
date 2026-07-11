# RestEyes 设计文档

日期:2026-07-10
状态:已确认

## 目标

一个轻量简洁的 macOS 菜单栏应用(Apple Silicon,macOS 26+),定时用全屏遮罩强制提醒用户休息眼睛、起身活动。休息期间屏蔽所有操作(覆盖所有窗口、所有 Space、所有显示器),仅在遮罩右下角保留一个按配置出现的「解锁」按钮。无常规图形界面:配置用文本文件,状态栏一个图标。**测试与编译全部通过 GitHub Actions 完成**——本地开发环境为 Linux,不做任何本地编译或测试,每次验证均以 push 触发 CI 为准。

## 非目标

- 不做偏好设置窗口、不做 GUI 配置界面。
- 不对抗系统级操作:电源键、Ctrl+Cmd+Q 系统锁屏、强制重启、SSH 远程登录均不屏蔽(用户态应用无此能力)。
- 不做 Intel (x86_64) 支持、不做付费签名与公证。
- 不做空闲检测(用户离开电脑时不暂停工作计时,睡眠/锁屏除外)。

## 技术选型

方案 A:Swift + AppKit,纯 Swift Package Manager 工程,无 Xcode 工程文件,零第三方依赖。产物为手工组装的 `RestEyes.app`。

理由:代码量最小,对窗口层级、多显示器、kiosk 模式的控制最直接;逻辑层可单元测试;产物只有几 MB。

## 行为设计(计时状态机)

状态:`working`(工作中)→ `warning`(预警)→ `resting`(休息遮罩)→ 回到 `working`,外加 `paused`(暂停)。

- **working**:倒计时 `work_minutes`。结束后进入 `warning`(若 `warn_seconds = 0` 则直接进入 `resting`)。
- **warning**:主屏右下角小浮窗显示「N 秒后休息」倒计时,不抢焦点、不打断输入。结束后进入 `resting`。
- **resting**:全屏遮罩,倒计时 `rest_minutes`。结束后自动解除,回到 `working` 并重置工作计时。
- **paused**:从菜单触发,暂停 1 小时后自动恢复,或手动点「恢复」提前恢复。恢复后工作计时重新开始。

解锁(提前结束 resting)途径:

1. 休息时间自然结束(自动)。
2. 遮罩右下角「解锁」按钮:按 `unlock_after` 配置,休息开始 N 秒后出现;`0` 为一开始就显示;`never` 为永不显示。
3. **紧急后门**:遮罩期间连续按 ESC 10 次(相邻两次间隔 ≤1.5 秒)强制解锁。任何配置下都有效,不可关闭,防止配置错误把用户锁死。

休息结束后锁屏(`lock_after_rest`,默认 on):

| 休息结束方式 | 是否锁屏 |
|---|---|
| 休息时间自然走完(含 breakNow 进入的休息) | **锁屏**(效果同 Ctrl+Cmd+Q) |
| 手动解锁(按钮或 ESC×10 后门) | 不锁 |
| 睡眠/锁屏中到期、唤醒时解除 | 不锁(屏幕刚解锁,不能锁回去) |

锁屏后现有"锁屏暂停计时"逻辑自动衔接:解锁返回时按离开时长补偿或重置工作计时。实现上 `BreakScheduler` 发出带原因的休息结束回调(`completed`/`unlocked`/`wake`,纯逻辑可测),UI 层仅在 `completed` 且配置开启时调用锁屏。

菜单动作语义:

- **立即休息**:跳过预警,直接进入 `resting`。
- **跳过下次休息**:设置一次性标记;下次工作计时结束时不进入休息,直接开始新一轮工作计时并清除标记。
- **暂停 1 小时**:进入 `paused`;菜单项变为「恢复」。

睡眠/锁屏处理(NSWorkspace 通知):

- 系统睡眠或屏幕锁定时暂停计时。
- 唤醒/解锁时:若离开时长 ≥ `rest_minutes`,视为已休息,工作计时重置重新开始;否则从暂停处继续。
- `resting` 状态中睡眠/锁屏:唤醒解锁时,`wake_ends_rest = on`(默认)直接结束休息回到 `working`(原因 `.wake`,不触发 `lock_after_rest` 锁屏);`off` 时仅当休息剩余时间已过才解除,否则遮罩按墙钟继续。

## 配置文件

- 路径:`~/.config/resteyes/config.txt`。首次启动若不存在,自动创建目录并生成带中文注释的默认配置。
- 格式:UTF-8 文本,每行 `key = value`,`#` 开头为注释行,键名大小写敏感,值两端空白去除。
- 容错:未知键忽略;非法值(解析失败、越界)回退为默认值并继续运行。配置错误绝不导致崩溃或锁死。
- 生效时机:菜单「重新加载配置」立即生效(工作计时按新值重新开始);每个工作周期开始时也自动重读一次。

默认配置内容:

```ini
# RestEyes 配置文件
# 修改后在状态栏菜单点「重新加载配置」生效

work_minutes = 20      # 工作时长(分钟,可用小数,如 0.5)
rest_minutes = 3       # 休息时长(分钟,可用小数)
warn_seconds = 10      # 黑屏前预警秒数,0 = 不预警直接黑屏
unlock_after = 60      # 解锁按钮出现时机:秒数;0 = 一开始就显示;never = 永不显示
message = 休息一下,眺望远方 🌿
                       # 遮罩上显示的文字,留空 = 纯黑屏
show_countdown = on    # 遮罩上是否显示剩余时间倒计时(on/off)
lock_after_rest = on   # 休息自然结束后进入系统锁屏;手动解锁不触发(on/off)
wake_ends_rest = on    # 睡眠/锁屏后唤醒解锁时,直接结束休息回到工作(on/off)
launch_at_login = on   # 开机自动启动(on/off)
```

数值边界:`work_minutes` 有效范围 (0, 1440],`rest_minutes` (0, 1440],`warn_seconds` [0, 600],`unlock_after` [0, 86400] 或字面量 `never`。越界回退默认值。`show_countdown`/`lock_after_rest`/`wake_ends_rest`/`launch_at_login` 仅认 `on`/`off`,非法值回退默认。

## 开机自启(launch_at_login)

- 用 macOS 官方 `SMAppService.mainApp` 注册/注销(ServiceManagement 框架,无需 TCC 权限);注册后出现在「系统设置 → 通用 → 登录项」,首次注册系统会发一条"已添加为登录项"通知(系统行为)。
- **仅在配置值变化时**才调用注册/注销:用 UserDefaults 记录上次应用的值,首启无记录时按配置应用一次;稳态启动与重载不做任何 SMAppService 调用。默认 `on`。
- 不与用户对抗:`SMAppService.status` 无法区分"从未注册"与"用户手动关闭"(都可能是 `.notRegistered`),因此不能按状态对账,否则每次启动会把用户手动关掉的开关翻回来。按值变化触发后,用户在系统设置里手动关闭不会被重新注册;想恢复可在系统设置开启,或把配置切 off 再改回 on 后重载。
- 裸二进制(无 bundle id,开发场景)静默跳过。

## 全屏遮罩与操作屏蔽

- 每个 `NSScreen` 一个无边框 `NSWindow`,黑色背景;窗口层级 `CGShieldingWindowLevel()`(高于 Dock、菜单栏、全屏应用);`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` 覆盖所有 Space 与全屏应用。
- 休息期间监听屏幕参数变化通知(插拔显示器、改分辨率),动态增删遮罩窗口。
- 输入屏蔽:
  - `NSApp.presentationOptions` 启用 kiosk 组合:隐藏 Dock、隐藏菜单栏、禁用进程切换(Cmd+Tab)、禁用强制退出对话框(Cmd+Opt+Esc)、禁用隐藏(Cmd+H)。
  - 遮罩窗口设为 key window,吞掉所有键盘事件(除 ESC 后门计数)。
  - 休息期间每秒定时将本应用重新激活到最前,防止其他应用抢焦点。
  - **不需要辅助功能/输入监控等任何 TCC 权限。**
- 遮罩内容:居中大字显示 `message`(留空则纯黑屏);其下可选显示剩余时间倒计时(`show_countdown`);右下角为半透明圆角「解锁」按钮(每个屏幕的遮罩都有),按 `unlock_after` 时机出现。
- 预警浮窗:主屏右下角小圆角深色浮窗,显示「N 秒后休息」,层级为普通浮动层,不抢焦点。

## 状态栏

- `NSStatusItem`,SF Symbol 眼睛图标,模板渲染(自动适配深浅色菜单栏)。
- `LSUIElement = true`,无 Dock 图标。
- 菜单项:
  1. **距下次休息 12:34** —— 禁用项,菜单打开期间每秒刷新;`paused` 时显示「已暂停」;`resting` 中显示「休息中」。
  2. 立即休息
  3. 跳过下次休息(设置后加勾选标记)
  4. 暂停 1 小时 ⇄ 恢复
  5. 打开配置文件(用系统默认文本编辑器打开)
  6. 重新加载配置
  7. 退出

## 代码结构

```
RestEyes/
├─ Package.swift               # swift-tools-version 5.10;库 + 可执行双 target
├─ Sources/RestEyesCore/       # 纯逻辑库(不 import AppKit,可单元测试)
│   ├─ Config.swift            # 配置解析/默认值/生成默认文件
│   ├─ BreakScheduler.swift    # 计时状态机(注入时钟)
│   └─ Format.swift            # 时间格式化(m:ss)
├─ Sources/RestEyes/           # 可执行 target(AppKit)
│   ├─ main.swift              # 入口:NSApplication 组装、AppDelegate、睡眠/锁屏
│   ├─ OverlayController.swift # 遮罩窗口、解锁按钮、ESC 后门、kiosk、预警浮窗
│   ├─ StatusItem.swift        # 状态栏图标与菜单
│   ├─ ScreenLocker.swift      # 系统锁屏(SACLockScreenImmediate + CGSession 降级)
│   └─ LoginItem.swift         # 开机自启注册对账(SMAppService)
├─ Tests/RestEyesCoreTests/    # 测试依赖库 target
│   ├─ ConfigTests.swift
│   ├─ BreakSchedulerTests.swift
│   └─ FormatTests.swift
├─ Resources/Info.plist        # 打包用模板(LSUIElement、LSMinimumSystemVersion 等)
├─ .github/workflows/build.yml
└─ README.md                   # 安装说明、配置说明、手动验收清单
```

(实施时把纯逻辑拆为 `RestEyesCore` 库 target:测试依赖库而非可执行 target,并在编译期强制逻辑层不依赖 AppKit。)

模块边界:

- `Config`:输入文本 → 输出配置结构体;不碰文件系统之外的东西(文件读写由薄封装负责)。
- `BreakScheduler`:纯状态机,依赖注入的时钟与定时器抽象;对外发出状态变更回调(进入预警/进入休息/解除休息/tick);对内接收动作(breakNow/skipNext/pause/resume/unlock/reload)。不 import AppKit。
- `OverlayController` / `StatusItem`:只消费状态机回调、只发送动作,互不依赖。

## 测试与编译(GitHub Actions)

开发闭环:本地(Linux)只写代码 → `git push` → GitHub Actions 在 macOS runner 上跑测试和编译 → 用 `gh run watch` / `gh run view --log` 查看结果。**任何「测试通过 / 编译成功」的结论都必须以 CI 运行结果为证据**,本地不运行 swift 工具链。

- Workflow `.github/workflows/build.yml`,触发:push(所有分支)、tag(`v*`)、workflow_dispatch。
- Runner:`macos-26`(Apple Silicon)。
- 步骤:`swift test`(失败则终止,不打包)→ `swift build -c release --arch arm64` → 组装 `RestEyes.app`(拷贝可执行文件、写 Info.plist)→ `codesign --force --deep -s -`(ad-hoc)→ zip → 上传 artifact;tag 推送时用 `gh release create`(或 action)附上 zip 发 Release。
- Info.plist 关键项:`LSUIElement = true`,`LSMinimumSystemVersion = 26.0`,`CFBundleIdentifier = com.resteyes.app`,`NSHighResolutionCapable = true`。
- 安装:下载 zip → 解压 → 拖入「应用程序」→ 首次右键打开(未公证)。README 说明,含 `xattr -cr` 备用命令。

## 测试策略

所有测试在 GitHub Actions 的 macOS runner 上执行(push 即触发),本地不跑测试。

- 单元测试(CI `swift test`):
  - `ConfigTests`:默认值、注释/空行、未知键、非法值回退、`never` 字面量、小数分钟、边界值。
  - `BreakSchedulerTests`:注入假时钟,验证完整周期状态迁移、warn=0 跳过预警、skipNext 一次性语义、pause/resume、breakNow、unlock 提前结束、睡眠唤醒三种分支(短暂/超过休息时长/休息中睡眠)。
- 手动验收清单(写入 README):多显示器覆盖、全屏应用覆盖、Cmd+Tab/Cmd+Q 被屏蔽、解锁按钮三种模式、ESC×10 后门、插拔显示器、深浅色菜单栏图标。

## 已知边界与风险

- 用户态应用无法屏蔽:电源键、Ctrl+Cmd+Q 系统锁屏、Touch ID 快速切换用户、强制重启。接受。
- 锁屏调用使用私有 API `SACLockScreenImmediate`(login.framework,即 Ctrl+Cmd+Q 的底层实现),无需 TCC 权限;若未来系统移除该符号,自动降级为 `CGSession -suspend`(回到登录窗口,效果等价略重)。个人分发可接受。
- 纯"熄屏"(显示器休眠)若未触发系统锁屏(用户未开"立即要求密码"),不产生任何通知,`wake_ends_rest` 检测不到;macOS 默认开启立即锁屏,不受影响。接受。
- `wake_ends_rest = on` 时,休息刚开始即手动锁屏再解锁可跳过休息——该设置的自然结果,由用户自律。接受。
- 某些系统弹窗(如 SecurityAgent 认证框)层级可能高于 shielding level。接受,属罕见场景。
- 未签名公证:首次打开需右键。接受,个人使用。
- `macos-26` runner 镜像若不可用,回退 `macos-15` + 最新 Xcode(deployment target 仍设 26.0,仅编译 SDK 版本差异)。
