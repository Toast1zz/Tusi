# Tusi 项目完整审计报告

> 审计日期：2026-08-18　基线：v1.8.0 (commit 4a78899)
> 项目：macOS 菜单栏翻译工具，Swift + SwiftUI + AppKit，纯 SwiftPM，无第三方依赖（除 uisfx 音频资源）

---

## 0. 总体结论

Tusi 是一个**质量相当高**的代码库：无警告构建（warnings-as-errors 通过）、44 个测试全绿、错误处理普遍周到（失败回退、损坏容错、越界保护都有覆盖）。但审计发现 **4 个 Swift 6 兼容性隐患、3 处 UI 一致性缺陷、若干稳定性改进点**。按影响面排序如下。

---

## 1. 代码鲁棒性（Robustness）

### 🔴 P0-1：非隔离静态可变状态 —— Swift 6 下编译错误 ✅ 已修复

**文件**：`Sources/Tusi/Core/TranslationService.swift:59`
```swift
#if DEBUG
nonisolated(unsafe) static var sessionOverride: URLSession?   // 已加 nonisolated(unsafe) + 文档
#endif
```
**问题**：`strict-concurrency=complete` 下报 `static property 'sessionOverride' is not concurrency-safe`。Swift 6 语言模式下这是硬错误。虽然当前测试串行执行未触发数据竞争，但这是定时炸弹。

**修复**：改为 `nonisolated(unsafe)` + 详细注释（测试专用、XCTest 串行、禁止并发写入）。这是 Swift 官方对测试注入点的推荐做法。

### 🟠 P1-1：HotkeyManager Carbon 回调捕获非 Sendable 值 ✅ 已修复

**文件**：`Sources/Tusi/HotkeyManager.swift:30`
```swift
let callback = manager.callback          // @Sendable 闭包，immutable
DispatchQueue.main.async { callback() }  // 只捕获 Sendable 的 callback
```
**问题**：`strict-concurrency` 报 `capture of 'manager' with non-Sendable type`。Carbon 回调在任意线程触发，`DispatchQueue.main.async` 里捕获 `manager` 有竞态风险（虽然 `takeUnretainedValue` + main async 实际上安全）。

**修复**：`callback` 属性改为 `@Sendable () -> Void`（init 后 immutable），回调闭包只捕获这个 Sendable 值。AppDelegate 侧用 `MainActor.assumeIsolated` 声明主线程上下文。

### 🟠 P1-2：PanelController 非隔离 deinit 访问隔离属性 ✅ 已修复

**文件**：`Sources/Tusi/PanelController.swift:83-90`
```swift
@MainActor
deinit {   // Swift 5.10+ 支持 @MainActor deinit
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
}
```
**问题**：`@MainActor` 类的 `deinit` 是非隔离的，访问 `@MainActor` 隔离属性在 Swift 6 下是错误。

**修复**：声明 `@MainActor deinit`，让清理在 main actor 上安全执行。

> 验证：三个问题修复后，`swift build -Xswiftc -strict-concurrency=complete` 达到 **0 警告**；build.sh 的 release 构建已加入 `-strict-concurrency=complete -warnings-as-errors` 门禁，任何并发隐患都会让发布构建失败。

### 🟡 P2-1：flusher 任务与主循环共享 buffer（当前安全，未来脆弱）

**文件**：`Sources/Tusi/Core/TranslationEngine.swift:339-352`
`flusher` 任务与 `for try await` 主循环都在 `@MainActor` 上下文中访问 `buffer`，**当前无竞态**（actor 串行）。但 `defer { flusher.cancel() }` 与显式 flush 之间的时序依赖是脆弱的——如果未来把 stream 消费移到非主 actor，这里会立刻产生数据竞争。

**建议**：给 `buffer` 加注释说明它依赖 actor 隔离，或改为 `AsyncStream` 的 buffering 机制。

### 🟡 P2-2：UpdateChecker 失败静默恢复

**文件**：`Sources/Tusi/Core/UpdateChecker.swift`
失败路径把 `state = .failed` 但 `checkTask = nil` 只在部分路径执行，deinit 里 `checkTask?.cancel()` 但未置 nil——重复调用 `check()` 时旧任务可能未清理。当前逻辑正确（`activeCheckID` 保护），但可读性差。

**建议**：统一 `checkTask = nil` 的时机，或用 `defer` 保证。

---

## 2. 前端美观性（UI/UX）

### 🔴 P0-2：UI 缺乏设计令牌（design tokens），字号/间距/动画散落 25+ 种组合 ✅ 已修复

**证据**：
- **字号**：25 种不同组合（8 / 9 / 9.5 / 10 / 10.5 / 11 / 11.5 / 12 / 12.5 / 14 / 15 / 18pt，多种 weight/design 组合）散落在 5 个 UI 文件
- **动画时长**：6 种（0.15 / 0.18 / 0.2 / 0.22 / 0.25 / 0.3 秒），部分乘以 `Theme.animationScale`，部分没有
- **圆角**：capsule / 6 / 8 / 9 / 10 / 20pt 混用
- **间距**：2 / 4 / 5 / 6 / 7 / 8 / 9 / 10 / 12 / 14 / 16 / 18pt 遍布

**影响**：不是某个元素难看，而是**整体缺乏一致性**——同样的"次要标签"在不同页面字号不同（10.5 vs 11 vs 12.5），同样的"轻量按钮"圆角不同。视觉上"差不多但总差一点"。

**修复**：`Theme.swift` 建立完整设计令牌体系（25 个字体令牌覆盖 9–18pt 全部层级 + weight/design 变体、4 个圆角、5 个动画时长 + `snappy()` 统一缩放）。所有 UI 文件字面量替换为令牌引用，令牌值与原字面量逐字节等价（零视觉变化）。仅保留两处有意的例外：骨架条 4pt 圆角（比控件圆角更细，已注释）和录音状态的条件字体。严格并发零警告，46 测试全绿。

### 🟠 P1-3：`Text` 与 `Image` 基线未对齐

底部栏按钮已修（pin 偏移），但全应用还有其他图标+文字混排处（如 `Label`、`Toast`、`ErrorBox`）未统一 `.alignmentGuide`，在部分字号下会有 ±1pt 抖动。

**建议**：为常用"图标+文字"组合（Label 行）建立统一辅助函数，用 `.firstTextBaseline` 对齐。

### 🟡 P2-3：设置页字段高度不一致

`labeledField` 的 `TextField` 有 `.padding(.vertical, 7)`，而 API Key 行因为 SecureField 换行视觉高度略不同。多语言目标语言的网格胶囊与开关行间距不统一（10 vs 12pt）。

**建议**：统一设置页行距为单一值（如 12pt），字段内边距统一。

### 🟡 P2-4：历史列表行高固定 86pt，长内容截断

`HistoryRecordRow` 用 `.lineLimit(1)` / `.lineLimit(2)` 硬截断，长输入/输出只显示省略号。对经常翻译长文本的用户，历史可读性受损。

**建议**：输入显示 2 行 + 输出 3 行，或在 hover 时展开 tooltip 显示全文。

---

## 3. 后端稳定性（Backend Stability）

### 🔴 P0-3：翻译请求无整体超时兜底 ✅ 已修复

**证据**：`URLSessionConfiguration.timeoutIntervalForResource = 300`（5 分钟），但**没有请求级超时**。流式传输本身可被 `consumeStream` 的 revision 检查取消，但一个"慢慢滴"的坏流（每 30 秒吐一个 token）会拖满 5 分钟资源超时，期间用户无法重新翻译（虽然可以点停止）。

**修复**：在 `stream()` 加**首 token 看门狗**（30 秒）——服务器接受连接但迟迟不吐数据（挂起网关、模型排队）时，看门狗取消流任务（AsyncBytes 迭代响应任务取消），转为明确的"服务器长时间无响应，请稍后重试"错误。看门狗与读循环共享的标记用 `OSAllocatedUnfairLock` 保护（strict-concurrency 零警告）。真正的用户取消仍以 `CancellationError` 传递，不会误报超时。

**验证**：新增 `testStreamFailsAfterFirstTokenTimeout`（挂起 mock，0.27s 快速失败）和 `testStreamWithImmediateDataIgnoresTimeout`（正常流无丢失/重复）。46 测试全绿。

### 🟠 P1-4：无自动重试（除 failover） ✅ 已修复

failover 只在"无输出前失败"时触发，遇到瞬时网络抖动（TCP reset、5xx）在单 profile 场景直接失败。

**修复**：`TranslationError.isTransient` 判定瞬时错误（5xx、截断流；4xx 判定性错误不重试），`consumeWithRetry` 在无输出时对同一 provider 快速重试 1 次（400ms 延迟）再走 failover。重构 attemptLoop 消除重复代码。新增 2 个测试：瞬时错误重试后成功、非瞬时错误不重试。48 测试全绿，严格并发零警告。

### 🟠 P1-5：API Key 变更无即时生效提示

Keychain 保存失败只显示 `keychainError`，但用户改完 key 后**不知道下次请求用的哪个 key**（有 debounce 250ms，若用户在 debounce 内退出，`flushPendingSaves` 兜底——这点做得对）。

**建议**：在设置页显示"配置已保存"的即时反馈（已有 `flashCopied` 类似机制可复用）。

### 🟡 P2-5：历史文件写是同步主线程

`saveHistory()` 在 main actor 同步写磁盘（注释说明是有意的——保证顺序）。50 条记录很小（<1ms），但极端情况（历史 50 条 × 32K 输入）可能到几 MB，主线程写会卡 UI。

**建议**：保持同步写（正确性优先），但限制单条记录大小（输入已 32K 封顶，输出无封顶——建议输出也封顶或截断存储）。

### 🟡 P2-6：日志与诊断缺失

无任何日志输出（无 `os.Logger` / `print`）。生产问题（请求失败、keychain 失败、更新检查失败）无法追溯。

**建议**：加 `os.Logger`（统一 `Logger(subsystem: "com.tusi.app", category: ...)`），关键路径打点，不落盘不刷屏，OSLog 天然低开销。

---

## 4. 测试覆盖缺口

| 缺口 | 现状 | 建议 |
|---|---|---|
| Swift 6 并发 | 无 | 加 `-strict-concurrency` 到 CI 构建，或直接迁移 Swift 6 模式 |
| 流式超时 | 无 | mock 慢流测首 token 超时 |
| 设置项持久化 | 部分 | soundEnabled 有测，其他 didSet 无 |
| 面板键盘导航 | 无 | Esc/⌘, 短路测试（需 UI 测试） |
| UpdateChecker 网络失败 | 无 | mock URLSession 测 failed 状态 |

---

## 5. 优先级路线图

### 第一优先级（正确性/兼容性，防未来炸）
1. **P0-1** sessionOverride 并发安全（Swift 6 兼容）
2. **P1-1** HotkeyManager Sendable 回调
3. **P1-2** PanelController deinit 隔离
4. **P0-3** 翻译请求首 token 超时兜底

### 第二优先级（体验提升）
5. **P0-2** Theme 设计令牌体系 + 系统化替换（最大观感收益）
6. **P1-4** 瞬时网络错误快速重试
7. **P2-4** 历史长文本可读性

### 第三优先级（打磨）
8. P2-1/2/3/5/6 各项小改进 + 测试补强

---

*审计方法：全量代码阅读 + `-strict-concurrency=complete` 编译 + `-warnings-as-errors` 构建 + 44 测试基线 + 静态分析（字号/动画/间距分布）。*

---

## 2026-08-19 跟进（二轮实施，基线同 v1.8.0）

本轮在上一轮基础上补齐以下项，并修正一个上一轮的表述错误：

### 修正：H1 — build.sh 门禁只覆盖 native
上一轮声称"release 构建已加入 `-strict-concurrency=complete -warnings-as-errors` 门禁"，**不成立**——该旗标只在 `native` 分支，`arm64`/`universal`/`release`（走递归）全部绕过，发行版无并发防线。已改为公共 `CONCURRENCY_FLAGS` 应用到所有 arch。

### 已完成

| 项 | 内容 | 落地 |
|---|---|---|
| H2 / P2-5 | 输出 64K 封顶 + `outputCapped` 标识，截断结果不自动复制、不播成功音，历史文件随之有界 | TranslationEngine + TranslatorView banner + 2 测试 |
| P2-6 | `os.Logger` 全补：keychain/app/sound 三类目接入（此前只有 translation/update） | Log.swift + SettingsStore/Keychain/AppDelegate/SoundPlayer |
| P1-5 | API Key 保存成功即时反馈"已保存到钥匙串"（1.6s 自消） | SettingsStore `keychainSaved` + SettingsView |
| P2-4 | 历史行 hover 完整全文 tooltip | HistoryRecordRow `.help` |
| M2 | UpdateChecker 可注入 URLSession + failed/available/upToDate 三态测试（此前 0 覆盖） | init 参数 + 3 测试 |
| L1 | ShortcutsView 残留 `.system(size: 11.5…)` 入 Theme | `shortcutCombo` / `shortcutComboRecording` |
| L3 | `saveHistory` 编码/写入失败打日志（原静默吞） | TranslationEngine.saveHistory |

验证：`-strict-concurrency=complete -warnings-as-errors` 构建 0 警告；测试 48 → **53 全绿**。

### 有意搁置（非遗漏）

- **P1-3 基线对齐**：纯视觉打磨，现有 pin 已单独修正，收益低且无机可试（需真机目测），未做
- **M3 方向检测防抖**：`NLLanguageRecognizer` 每键在主线程跑。加防抖会破坏"输入立即切方向"的即时反馈，且现有测试依赖同步检测（`engine.input = …` 后立即断言 `engine.source`）。保留同步，标注为将来 UI 层优化选项
- **L2 重定向目标校验**：URLSession POST 跨主机重定向会重发 `httpBody`；OpenAI 兼容端点几乎不重定向 POST，概率极低，未加 session 级 delegate（代价>收益）
