# Tusi 当前代码完整审计与优化方案

> 审计日期：2026-08-27  
> 审计基线：`main` / `fe2ec9b` / `v1.11.1` / build 32  
> 项目路径：`/Users/toast1/Projects/Tusi`  
> 审计范围：用户体验、界面稳定性与审美、后端与工程稳定性  
> 文档性质：只读审计结论与实施方案，不代表下列改动已经实现

---

## 1. 执行摘要

Tusi 当前不是一个“需要推倒重写”的项目。它的代码质量明显高于一般同体量的 macOS 菜单栏工具，尤其是以下基础已经做得较好：

- 翻译任务具有取消、请求 revision 和旧请求防覆盖机制。
- 主用/备用故障切换明确禁止在收到 token 后拼接两个供应商的结果。
- 正常翻译使用未发布缓冲，完成后一次性提交；用户停止时才展示带“不完整”标记的部分结果。
- API Key 使用 Keychain，而不是 UserDefaults 或明文文件。
- 历史记录使用原子写入，并能在单条记录损坏时尽量恢复其他记录。
- 现有 CI 已运行测试、动画曲线门禁和严格并发 release 构建。
- 当前 `swift test` 共 84 项测试全部通过。
- 当前 `-strict-concurrency=complete -warnings-as-errors` 构建通过。

当前最需要处理的不是再做一轮零散字号、圆角和动画调参，而是以下四类问题：

1. **请求恢复逻辑存在实现与注释不一致**：真实 `URLError` 和看门狗超时不会进入当前的“瞬时错误重试”。
2. **竞速模式存在确定性错误分支**：先结束的空响应会取消另一条可能成功的请求。
3. **流接收缺少进行中的内容上限**：64,000 字限制只在流结束后执行，持续输出的异常服务仍可造成较大内存与主线程压力。
4. **界面存在数个完整工作流断点**：设置页在低高度屏幕不可滚动、没有真实可点击的翻译主按钮、历史截断后恢复成“完整结果”、快捷键注册状态可能与设置显示不一致、英文文案存在缺失。

审计没有发现必须立即停止发布的 P0 级崩溃或已证实的数据泄漏问题；但下文的 P1 项应在继续扩展功能前完成，否则新增供应商、本地模型或更长文本只会放大现有边界问题。

---

## 2. 审计方法与证据边界

本次使用以下方法：

- 阅读全部 `Sources/Tusi` Swift 源码、测试、构建脚本、CI、README 和现有审计/方案文档。
- 对 `Sources/Tusi` 建立临时代码结构图：23 个 Swift 文件、555 个节点、1,163 条关系、21 个社区。
- 重点逐行检查：
  - `TranslationEngine`
  - `TranslationService`
  - `SettingsStore`
  - `PanelController`
  - `TranslatorView`
  - `SettingsView`
  - `HotkeyManager`
  - `Keychain`
  - `UpdateChecker`
- 运行 `swift test`：84 tests，0 failures。
- 运行严格并发和 warnings-as-errors 构建：通过。
- 检查当前 Git 状态，未修改任何现有源码或用户已有文档。

### 2.1 视觉审计限制

本轮尝试用 `TUSI_PREVIEW` 隔离预览检查真实界面，但预览进程与 Computer Use/LaunchServices 的交互异常，未能得到可信截图。期间额外启动的项目 `build/Tusi.app` 进程已经被准确识别为开发构建，而不是第二次安装。

因此：

- 布局可达性、状态语义、材质叠加和无障碍结论可由源码确认。
- “具体看起来是否发灰、是否有一帧闪烁、某个 0.5pt 光学偏移是否合适”仍必须以真机截图和交互录像验收。
- 本文不会把未完成的真机目测描述为“视觉已验证”。

### 2.2 结论标签

本文使用三种标签：

- **已确认缺陷**：从当前控制流可以直接推出错误结果，不依赖主观判断。
- **结构性风险**：当前通常可工作，但在长文本、高速流、并行测试或异常环境下缺少边界。
- **产品优化建议**：不存在唯一正确实现，需要按产品体验选择并完成真机验收。

---

## 3. 当前架构与高耦合中心

```text
AppDelegate
  ├─ SettingsStore ── UserDefaults / Keychain / SMAppService
  ├─ TranslationEngine
  │    ├─ LanguageDetector
  │    ├─ TranslationService ── URLSession / SSE / OpenAI-compatible API
  │    ├─ SmartQuotes
  │    ├─ History JSON
  │    ├─ NSPasteboard
  │    └─ SoundPlayer
  ├─ PanelController ── NSPanel / Carbon shortcuts / focus / screen positioning
  ├─ UpdateChecker ── GitHub Releases API
  └─ RootView
       ├─ TranslatorView
       ├─ SettingsView
       └─ ShortcutsView
```

结构图和源码都表明，当前最高风险中心是：

1. `TranslationEngine`：同时负责状态机、供应商执行、重试、竞速、结果提交、历史、剪贴板和反馈。
2. `SettingsStore`：同时负责 Profile、Keychain 防抖、UserDefaults、快捷键、登录项、声音和链路解析。
3. `PanelController`：同时承担窗口生命周期、定位、尺寸、焦点、局部快捷键和快捷键录制。
4. `TranslatorView`：同时处理输入测高、结果滚动、历史、语言选择、底栏和 Toast。

这些模块当前仍可维护，但已经接近“任何新功能都会触碰多个状态域”的临界点。后续重构应先补行为测试，再拆边界，不能先做大规模文件搬运。

---

## 4. 必须保留的产品与架构约束

以下是当前实现和已确认体验的基础，优化时不得无意破坏：

1. 底层继续使用 SSE，以保留首 token 检测、可取消性和流完整性判断。
2. 正常翻译期间不逐 token 展示；保持骨架等待，完成后一次性发布完整结果。
3. 用户主动停止且已经收到内容时，可以一次性显示部分结果，但必须标记“不完整”。
4. 请求失败时，未完成缓冲不得作为完整译文展示。
5. 任一供应商产生 token 后，不得切换后端并拼接另一份结果。
6. 编辑输入、切换目标语言或切换模式时，旧请求必须取消，旧回调不得覆盖新请求。
7. 本地模型是独立模式，不进入主用/备用竞速和自动故障切换链。
8. 不重新引入持久化窗口高度、原文/译文分割窗或空面板恢复成巨大窗口的行为。
9. UI 保持克制的原生 macOS 工具风格，不引入品牌渐变、光晕、厚重磨砂或装饰性卡片堆叠。
10. API Key 不写入 UserDefaults、日志、诊断文件或历史记录。

---

## 5. 优先级总表

| ID | 优先级 | 类型 | 结论 | 主要文件 |
|---|---:|---|---|---|
| BE-001 | P1 | 已确认缺陷 | 真实传输错误与看门狗超时不会按注释重试 | TranslationEngine / TranslationService |
| BE-002 | P1 | 已确认缺陷 | 竞速中先完成的空响应会取消另一条成功路径 | TranslationEngine |
| BE-003 | P1 | 结构性风险 | 流进行中没有内容硬上限，最终 cap 执行过晚 | TranslationEngine / TranslationService |
| BE-004 | P1 | 结构性风险 | 每个 token 回到 MainActor，快速本地流可能拖慢交互 | TranslationEngine |
| BE-005 | P2 | 兼容性风险 | SSE 解码失败被静默跳过，终止 chunk 的 schema 偏严格 | TranslationService |
| BE-006 | P2 | 安全加固 | 未显式限制携带正文和 Authorization 的跨源重定向 | TranslationService |
| BE-007 | P1 | 结构性风险 | 加载历史时不重新应用容量与字段上限 | TranslationEngine |
| BE-008 | P2 | 结构性风险 | Keychain 读取无法区分不存在、锁定、拒绝和损坏 | Keychain / SettingsStore |
| BE-009 | P3 | 架构债务 | 固定三元素 Profile 数组依赖裸下标和隐含长度不变量 | SettingsStore / TranslationEngine |
| BE-010 | P2 | 已确认问题 | 测试连接只验证 HTTP 200，不验证是否为可用模型响应 | TranslationService / SettingsView |
| BE-011 | P2 | 兼容性问题 | 裸 `::1` 被识别为 loopback 意图但 URL 仍无法正确构造 | TranslationService / SettingsStore |
| UX-001 | P2 | 产品建议 | 主界面没有真实可点击的“翻译”主操作 | TranslatorView |
| UX-002 | P2 | 产品建议 | 所有失败只有“重试”，缺少设置/诊断/稍后重试动作 | Components / TranslatorView |
| UX-003 | P2 | 产品建议 | 输入超限反馈太短，用户可能不知道正文尾部已丢失 | TranslationEngine / TranslatorView |
| UX-004 | P1 | 已确认缺陷 | 历史字段被截断，恢复后却呈现为完整结果 | TranslationEngine / TranslatorView |
| UX-005 | P1 | 已确认缺陷 | 全局快捷键注册失败后 UI 值与实际生效值可能不同 | HotkeyManager / AppDelegate / SettingsStore |
| UX-006 | P2 | 产品建议 | 本地模型模式在主界面不可持续感知 | SettingsView / TranslatorView |
| UX-007 | P2 | 已确认问题 | “API Key 不会上传”表述不够准确 | SettingsView / Localizable.strings |
| UX-008 | P2 | 已确认问题 | Launch at Login 注册失败静默回滚 | SettingsStore / SettingsView |
| UX-009 | P2 | 已确认问题 | 剪贴板写入结果未检查，可能显示虚假的“已复制” | TranslationEngine |
| UX-010 | P1 | 已确认缺陷 | 新增功能英文文案缺失，英文系统会混入中文 | Localizable.strings / 多个 UI 文件 |
| UX-011 | P3 | 状态债务 | soundVolume 可持久化且有测试，但界面没有音量控件 | SettingsStore / SettingsView |
| UX-012 | P2 | 口径问题 | provider.order 只是 OpenRouter 偏好顺序，不是严格路由 | SettingsStore / TranslationService / SettingsView |
| UX-013 | P3 | 已知取舍 | 纯汉字日文、长文本前 400 字偏差可能导致源语言误判 | LanguageDetector |
| UI-001 | P1 | 已确认缺陷 | 设置页无滚动容器，低可用高度时底部设置不可达 | SettingsView / PanelController |
| UI-002 | P2 | 界面稳定性 | 跨屏与满高 clamp 仍可能让面板越过可见边界 | PanelController |
| UI-003 | P2 | 无障碍 | selected trait、Tab 顺序和溢出可发现性不完整 | Components / Views |
| UI-004 | P2 | 可发现性 | 长文本和横向语言列表普遍隐藏滚动提示 | TranslatorView |
| UI-005 | P2 | 视觉风险 | 主材质、Toast 材质、顶部高光可能形成多层发灰 | Components |
| UI-006 | P2 | 动效风险 | ZStack 页面共存和窗口测高可能产生二次尺寸变化 | RootView / PanelController |
| ENG-001 | P2 | 工程风险 | 测试依赖全局静态 seam，未来并行化存在相互污染 | TranslationService / Tests |
| ENG-002 | P3 | 架构债务 | Engine、SettingsStore 职责过多，扩展成本上升 | Core |
| ENG-003 | P2 | 发布体验 | 未公证，首次安装需要绕过 Gatekeeper | build.sh / 发布流程 |
| ENG-004 | P2 | 可运维性 | 缺少用户可导出的脱敏诊断收据 | Log / 各服务 |
| ENG-005 | P3 | 文档债务 | README 和多个方案文档存在互相冲突或过期表述 | README / 根目录文档 |
| ENG-006 | P3 | 元数据债务 | package.json 版本、许可证和 test script 与项目不一致 | package.json |

---

## 6. 后端稳定性详细结论

### BE-001：瞬时错误重试分类不完整

**证据**

- `TranslationEngine.consumeWithRetry` 只检查：
  - `(error as? TranslationError)?.isTransient ?? false`
- `TranslationError.isTransient` 只把以下错误视为瞬时：
  - HTTP 5xx
  - truncated stream
- `TranslationService` 对普通 URLSession 错误直接把原始 `URLError` 抛给调用方。
- 首 token/idle 看门狗生成 `.http(0, message)`；`0 >= 500` 为 false，因此也不会重试。

**触发条件**

- DNS 短暂失败。
- TCP reset。
- `networkConnectionLost`。
- `timedOut`。
- 服务器已返回 header，但首 token 或中途内容超时。

**影响**

- 注释和测试给开发者的印象是“网络抖动会快速重试一次”，真实生产错误却可能直接失败或立即切换备用。
- 单 Profile 用户丧失可恢复性。
- 备用 Profile 用户可能多消耗一次不同供应商请求，而不是先低成本重试原供应商。

**建议实现**

建立统一错误域，例如：

```swift
enum RequestFailure {
    case cancelled
    case transport(URLError.Code)
    case timeout(stage: TimeoutStage)
    case http(status: Int, message: String, retryAfter: Duration?)
    case invalidConfiguration(ConfigurationFailure)
    case protocolViolation(ProtocolFailure)
    case emptyResponse
}
```

统一提供：

- `isRetryable`
- `isFailoverEligible`
- `userMessage`
- `diagnosticCode`

建议策略：

- 用户取消：不重试、不 failover。
- DNS、连接丢失、超时、HTTP 5xx：无 token 时快速重试一次。
- 429：不做 400ms 盲重试；有 `Retry-After` 时提示等待，也可在无 token 时切备用。
- 401/402/403：不重试同一 Profile；如果备用凭证独立，可以 failover。
- URL/HTTP 安全配置错误：不重试当前 Profile，可以尝试独立备用 Profile。
- 任何已经产生 token 的失败：继续保持不重试、不 failover。

**测试要求**

- `URLError(.timedOut)` 首次失败、第二次成功。
- `URLError(.networkConnectionLost)` 首次失败、第二次成功。
- 看门狗首 token timeout 可重试。
- idle timeout 在已有 token 后不得重试和 failover。
- 429 不进行固定 400ms 快速重试。
- 用户取消永远不显示超时或网络错误。

---

### BE-002：竞速模式会被空响应提前终止

**证据**

`TranslationEngine.raceForFastest` 在任一 leg 返回 `.completed(buffer)` 后：

1. 把 buffer 赋给 `pendingOutput`。
2. 调用 `commitPendingOutput`。
3. 无论结果是否 usable，立即 `group.cancelAll()`。
4. usable 为 false 时返回 `.emptyResponse`。

因此，“供应商 A 先返回空内容，供应商 B 稍后返回正常内容”会被错误地判定失败。

**正确语义**

竞速选择的不是“第一个结束的请求”，而是“第一个完成并产生可用结果的请求”。

**建议实现**

- leg 完成且内容为空：记录该 leg 为 unusable，继续等待另一个 leg。
- leg 失败：记录错误，继续等待另一个 leg。
- leg 完成且内容可用：提交、取消另一条、返回 winner。
- 两条都空：返回 empty response。
- 一空一失败：返回失败，并保留更有诊断价值的错误。
- 两条都失败：返回组合错误，但 UI 不必暴露两个冗长原始错误。

**测试要求**

- 先空、后成功。
- 先失败、后成功。
- 先空、后失败。
- 双空。
- 双失败。
- winner 提交后 loser 永远不能覆盖结果或重复写历史。

---

### BE-003：流内容上限执行过晚

**证据**

- `pendingOutput += piece` 在流存续期间没有上限。
- `maxOutputCharacters = 64_000` 只在 `commitPendingOutput` 和用户停止后执行。
- race mode 为两个 leg 各维护一个本地 buffer，同样没有进行中上限。
- 只要供应商持续发送 token，idle watchdog 就不会触发。

**影响**

- 异常或恶意兼容服务可以持续输出，直到 300 秒 resource timeout。
- 内存占用、字符串拼接开销和主 actor 工作量都不受 64,000 字最终 cap 约束。
- race mode 可能同时承担两份大输出。

**建议实现**

- 在消费过程中同时维护：
  - UTF-8 byte count
  - 用户可见 Character count
- 达到上限后主动停止上游流，不继续读取到服务器自行结束。
- 使用专门的 `.capped` outcome，而不是伪装成普通完成或网络取消。
- capped 结果继续遵守当前语义：
  - 显示截断提示。
  - 不自动复制。
  - 不播放成功音。
  - 历史记录保存截断标记。
- HTTP 非 200 错误正文继续保持独立的 8 KiB 上限。

**测试要求**

- 单次 yield 超过上限。
- 100,000 个单字符 chunk。
- 永不结束但持续产生内容的 stream。
- race 两条同时大量输出。
- 达到 cap 后上游 `onTermination` 收到取消。
- 内存和完成时间有明确预算。

---

### BE-004：每个 token 仍在 MainActor 消费

**证据**

`TranslationEngine` 整体为 `@MainActor`，`consumeStream` 和 `consumeRaceLeg` 都逐 chunk 执行字符串追加。

当前虽然不对每个 token 发布 `@Published output`，避免了 SwiftUI 重绘，但不代表没有主线程成本。快速本地模型或极细粒度 SSE 仍会让主 actor 处理大量 continuation resume 和字符串追加。

**建议实现**

引入可测试的请求执行器：

```text
TranslationCoordinator (@MainActor)
        │
        └─ ProviderAttemptRunner (non-main isolation)
              ├─ SSE decode
              ├─ bounded accumulation
              ├─ timeout/retry classification
              └─ returns one typed outcome
```

主 actor 只处理：

- translating stage 变化。
- 最终完整结果。
- 用户停止时选定的部分结果。
- typed error。
- toast/history/clipboard/sound 副作用。

**验收预算**

- mock 10,000 个单字符 chunk 时，停止按钮仍能在 200ms 内响应。
- 主线程单次 stall 不超过 50ms。
- 完成结果与当前实现逐字符一致。

---

### BE-005：SSE 兼容层需要显式协议边界

**现状优点**

- 支持 `[DONE]`。
- 支持无 `[DONE]` 但有非空 `finish_reason`。
- 缺少两者时判定 truncated，避免把断流当完整结果。
- 非 200 错误正文限制为 8 KiB。

**当前风险**

- 不能解码的 JSON chunk 被静默跳过。
- `StreamChunk.Choice.delta` 是必填；部分兼容服务的 usage/终止 chunk 可能没有 delta。
- 没有区分“无内容”和“所有内容都因为协议不兼容被跳过”。
- reasoning-only 活动、SSE 注释、keepalive 与真正内容没有单独诊断。

**建议实现**

- `delta` 改为 optional。
- 对 event 类型和忽略原因做计数，不记录正文。
- 若收到终止信号但所有内容事件均无法解码，返回 protocol violation，而不是 empty response。
- 保留严格完整性规则，不因“有过文本”就把无终止信号的断流判为成功。
- 增加 OpenAI、OpenRouter、Ollama、LM Studio 和至少一个非标准网关的固定 fixture 契约测试。

---

### BE-006：跨源重定向需要显式限制

翻译请求同时包含：

- `Authorization: Bearer ...`
- 用户源文。
- 模型名、附加要求和目标语言提示。

依赖 URLSession 默认重定向策略不够清晰。建议通过 delegate 实施：

- 只允许 HTTPS 到 HTTPS。
- 默认只允许同 host、同有效端口。
- 禁止携带认证和正文跳转到新 host。
- 禁止远程 HTTPS 降级 HTTP。
- 对确实需要重定向的兼容服务，使用用户可见、按 Profile 配置的明确例外，而不是全局放宽。

测试必须捕获最终请求 host、Authorization 和 body 是否被重发。

---

### BE-007：历史加载需要重新归一化

当前保存新历史时会限制：

- 最多 50 条。
- input/output 各最多 4,000 字。

但 `loadHistory` 成功解码旧文件后会直接赋给 `history`，没有重新应用容量和字段上限。旧版本、手工修改或异常文件可以加载超大数组和超大字段；下一次保存时仍可能让主线程编码较大数据。

建议：

- 加 `HistoryEnvelope(schemaVersion, records)`。
- 加载后统一：
  - 限制记录数。
  - 限制字段字节与字符数。
  - 验证时间戳和语言字段。
  - 保存 `inputTruncated/outputTruncated`。
- 无法解析的原文件改名为 `history.corrupt-<timestamp>.json`，不要静默覆盖。
- 如果保留了部分记录，日志写入恢复数量和丢弃数量，不写入内容。

---

### BE-008：Keychain 错误域过于扁平

当前 `Keychain.read` 对所有非 `errSecSuccess` 都返回 nil，因此上层无法区分：

- Item 不存在。
- 首次解锁前不可访问。
- 用户拒绝访问。
- 权限或签名要求变化。
- Keychain 数据损坏。
- 其他 Security.framework 错误。

建议：

- `loadKeys()` 改为 throwing 或返回 typed result。
- 只有 `errSecItemNotFound` 转成“未配置”。
- `errSecInteractionNotAllowed` 转成“设备解锁后重试”。
- 用户拒绝和签名异常应显示可恢复说明，但不要自动删除真实 Keychain item。
- 诊断中只记录 OSStatus，不记录 Key 值。

---

### BE-009：固定三元素 Profile 数组是隐含不变量

多个位置直接使用：

- `profiles[0]`
- `profiles[1]`
- `profiles[SettingsStore.localProfileIndex]`
- `profiles[primaryIndex]`

UI 大多数位置已经有 safe index，但 Core 层仍依赖数组长度永远为 3。

建议逐步迁移为：

```swift
enum ProfileSlot: Int, CaseIterable {
    case primary
    case backup
    case local
}

struct ProfileSet {
    var primary: APIProfile
    var backup: APIProfile
    var local: APIProfile
}
```

这不是第一批改动。应在 P1 行为测试齐全后执行，以减少迁移回归。

---

### BE-010：测试连接只证明 HTTP 200，不证明模型可用

`TranslationService.testConnection` 发送一个非流式、`max_tokens = 1` 的请求，但收到 HTTP 200 后不会解析响应 JSON，也不检查是否存在 `choices`、`message.content` 或兼容错误对象。

因此以下响应都可能被设置页显示为“连接正常”：

- HTTP 200 的 HTML 登录页。
- HTTP 200 的网关错误 JSON。
- HTTP 200 但 schema 与 OpenAI-compatible 完全不兼容。
- 模型字段被忽略、返回其他业务数据的代理。

建议：

- 检查 Content-Type，但不能只依赖它，因为部分兼容服务设置不规范。
- 解析最小 OpenAI chat completion schema。
- 接受 content 为空但 finish reason 合法的 1-token 探测边界，需要结合实际 fixture 定义。
- 如果 response 是 `{error: ...}`，即使 HTTP 200 也判失败。
- 测试结果区分：网络可达、认证通过、模型可调用、响应协议兼容。
- 设置页可以最终只显示一个简洁结论，详细阶段放在 tooltip/诊断中。

---

### BE-011：裸 IPv6 loopback 正规化不完整

`looksLoopback` 把以 `::1` 开头的无 scheme 字符串识别为本机地址，并尝试补 `http://`；但 `http://::1` 不是合法的带 host URL，IPv6 literal 需要方括号。`APIConfig.displayHost` 对裸 `::1` 也会因为同样原因得到空 host，进而误判为 requiresAuth。

建议：

- 把裸 `::1`、`::1:<port>` 正规化为 `[::1]`、`[::1]:<port>` 后再交给 URLComponents。
- 明确支持并测试：
  - `::1`
  - `[::1]`
  - `[::1]:11434/v1`
  - `http://[::1]:11434/v1`
- 拒绝非 loopback IPv6 的远程 HTTP。
- `endpoint(for:)` 与 `displayHost/requiresAuth` 必须共享同一正规化结果，不能各自解析。

---

## 7. 用户体验详细结论

### 7.1 保留原子展示，但改善等待感知

当前完整结果一次性出现是明确产品选择，不应恢复逐 token 展示。优化方向应是让等待状态更可信，而不是重新引入逐字跳动：

- 请求开始：显示“正在连接”。
- 收到首个有效内容事件后：显示“正在生成完整结果”。
- 超过 3 秒：显示已等待时间，不显示虚假百分比或 ETA。
- stop 始终可见、可键盘访问。
- race mode 停止时明确放弃两路请求；如果要展示部分结果，必须选定单一 leg，不能合并两个 buffer。
- README 的 “Streaming output” 改为准确说明：底层流式传输、界面完成后展示完整结果。

### 7.2 UX-001：增加真实翻译按钮

`TranslatorView.bottomBar` 在“有输入、无结果、未翻译”状态只显示静态 `Text("⏎ 翻译")`。

问题：

- 鼠标用户没有可点击的主操作。
- VoiceOver 用户无法把它当按钮激活。
- 第一次使用者必须猜测 Return 是唯一入口。

建议：

- 使用真实 `Button`，文案为“翻译”，可附 Return 键提示。
- 输入为空时 disabled，而不是完全消失。
- 翻译中由 stop 按钮占据同一稳定尺寸区域，避免底栏横向跳动。
- 保留 Return 快捷键。
- 不把复制按钮变形成停止按钮，维持现有状态语义。

### 7.3 UX-002：错误框需要上下文动作

当前所有错误都只有“重试”。建议按错误类型映射动作：

| 错误 | 主动作 | 次动作 |
|---|---|---|
| 未配置 Profile | 打开对应设置 | 无 |
| 无效 URL / HTTP 安全限制 | 打开该 Profile | 复制脱敏诊断 |
| 401/402 | 打开 API Key/Profile | 测试连接 |
| 429 | 稍后重试 | 切换 Profile（如可用） |
| 网络瞬时错误 | 重试 | 复制诊断 |
| 协议不兼容 | 查看配置说明 | 复制诊断 |
| 结果中途断流 | 重试 | 复制诊断 |

错误正文不应直接无限展示供应商原始 HTML 或内部堆栈。

### 7.4 UX-003：输入上限需要持续反馈

当前超过 32,000 字会截断，并显示 2 秒 Toast。Toast 容易被忽略，用户可能继续操作但不知道尾部已丢失。

建议：

- 28,000 字后显示计数。
- 超限粘贴后显示持续 banner，直到用户再次编辑或确认。
- 提示中明确“只保留前 32,000 字”。
- 不自动把丢失的部分复制到其他位置，避免改动用户剪贴板。
- 对超长文本提供“分段翻译”只能作为未来独立功能，不能在本批隐式拆分并拼接。

### 7.5 UX-004：历史截断必须诚实呈现

当前历史归档字段截至 4,000 字，但 `restoreHistory` 会把它恢复成 `.done`，没有任何截断标记。

风险：

- 用户可能复制一份不完整译文，却以为是完整结果。
- 用户可能对已经截断的历史输入再次翻译。
- 历史 UI 的 tooltip 也只能展示被截断后的字段，不是真正全文。

建议：

- Record 增加 `inputTruncated/outputTruncated`。
- 历史行显示“摘要”或 scissors 标记。
- 恢复后显示持久的“不完整历史摘要”提示。
- 截断输入的“重新翻译”必须明确确认。
- 历史行增加分别复制原文/译文的按钮。
- “清空历史”增加确认或 5 秒撤销。

### 7.6 UX-005：快捷键注册需要事务一致性

当前顺序是：

1. Settings 先保存新组合。
2. Combine publisher 通知 AppDelegate。
3. HotkeyManager 注销旧组合并注册新组合。
4. 新组合失败时，HotkeyManager 尝试恢复旧组合。
5. Settings 仍显示并保存新组合。

这会形成：

```text
界面显示：新快捷键 A
实际生效：旧快捷键 B
```

建议：

- 全局快捷键单独使用“提议 -> 注册 -> 成功后提交设置”的事务。
- 注册失败时 UI 保持旧值，并显示冲突原因。
- 如果旧快捷键恢复也失败，明确显示“当前无全局快捷键”。
- 录制本地快捷键时，对无修饰字母/数字不能只警告后继续保存；至少需要第二次确认，因为它会让输入字符不可用。

### 7.7 UX-006：本地模型模式需要在主界面可感知

当前 `useLocalModel` 是设置页中的持续模式开关。用户开启后回到翻译页，底栏不持续显示当前正在使用本地独立 Profile。

建议：

- 在底栏或方向/语气附近显示克制的“本地”状态标记。
- tooltip 显示模型名和 host。
- 不显示完整 URL，不挤占主操作。
- 未配置但模式开启时，错误框直接提供“配置本地模型”。
- 不把本地 Profile 放入竞速或自动 fallback。

### 7.8 UX-007：API Key 隐私文案需要准确

当前文案：

> API Key 仅保存在本机钥匙串，不会上传

API Key 必须随 Authorization header 发送给用户配置的 API 服务，因此“不会上传”容易被理解为从不离开设备。

建议文案：

> API Key 仅保存在本机钥匙串，只发送给你配置的 API 服务

英文同步表达同一事实。

### 7.9 UX-008：Launch at Login 失败不能静默

当前 SMAppService register/unregister 失败时，设置值静默回滚。用户看到开关自己弹回去，但没有原因。

建议：

- 保存 typed error。
- 设置页显示“无法启用登录启动”。
- 对 `.requiresApproval` 提供“打开系统设置”的按钮。
- Preview/test 模式注入假的 LoginItemService，不调用真实 SMAppService。

### 7.10 UX-009：剪贴板反馈必须检查结果

`NSPasteboard.setString` 返回 Bool，当前代码忽略返回值，随后一定显示 copied。

建议：

- 只有写入成功才显示“已复制”。
- 失败时显示短错误，不清空现有结果。
- 自动复制失败不能播放成功复制反馈。
- 测试通过可注入 Clipboard 协议覆盖成功与失败。

### 7.11 UX-011：音量状态没有用户控制入口

`SettingsStore.soundVolume` 会持久化、恢复并实时应用到 `SoundPlayer`，测试也覆盖默认值和恢复值，但当前 Settings 只提供声音开关和试听按钮，没有任何 Slider、Stepper 或菜单可以修改音量。

这形成一项无法从产品界面到达的状态：

- 如果该设置仍是产品需求，使用原生小型 Slider，并在试听时立即应用。
- 如果音效音量应固定，删除对用户不可见的 Published preference，只在 SoundPlayer 内保留一个经过试听确定的常量。
- 不应长期保留“可持久化但用户永远无法修改”的设置。

### 7.12 UX-012：OpenRouter 路由文案应区分偏好与强制

当前代码只发送：

```json
{"provider":{"order":["novita","together"]}}
```

这表示 OpenRouter 的供应商优先顺序，不等于：

- `provider.only`
- `allow_fallbacks: false`
- 只允许指定供应商

建议把设置标签从泛化的“供应商路由”改为“供应商优先顺序”，说明 OpenRouter 仍可能回退到其他可用供应商。如果未来支持严格模式，必须用独立开关明确展示成本和可用性风险，不能复用当前文本字段隐式切换。

### 7.13 UX-013：语言检测存在应被明确记录的取舍

当前方向检测只分析前 400 个字符，并优先使用 Kana/Hangul，再比较 Han 与 Latin word 数量。它对常见中英技术混排非常实用，但仍有边界：

- 不含假名的纯汉字日文可能被判为中文。
- 长文本开头与主体语言不同时，前 400 字可能代表性不足。
- CJK 标点被纳入 Han 范围，极短标点文本会偏向中文默认。

建议先把这些行为写成测试和产品说明，不要直接换回 `NLLanguageRecognizer`。长期可用置信度加人工方向按钮解决，而不是在每次键入时引入复杂异步检测。

---

## 8. 界面稳定性与审美详细结论

### 8.1 UI-001：设置页必须在低可用高度下可滚动

`SettingsView` 是一个长 `VStack`，没有外层 `ScrollView`。`PanelController` 会把窗口高度限制到屏幕可用高度，但 SwiftUI 内容自身不会因此自动变得可滚动；超出部分会被 PanelContainer 的圆角 mask 裁掉。

触发环境：

- 低分辨率外接屏。
- 投影仪。
- Dock 占用较大。
- 英文长文案。
- 辅助字体或未来增加设置行。
- Keychain/快捷键错误文案展开。

建议：

- Settings/Shortcuts 页使用纵向 ScrollView。
- Header 可保持顶部可见，但不要做厚重 sticky card。
- 翻译页继续采用内容驱动的紧凑高度。
- 不保存用户手动高度。
- 不重新引入 split view。
- 小屏下底部所有 Toggle、更新检查和错误信息必须可到达。

### 8.2 UI-002：每次 show 都应按当前屏幕重新 clamp

当前 `position()` 使用持久宽度和 `desiredHeight`，但高度主要由之前的内容测量决定。

边界问题：

- 从大屏隐藏后，在小屏通过快捷键重新打开，可能沿用过大的 desiredHeight。
- 高度被 clamp 到完整 `visibleFrame.height` 后，顶部仍额外留 6pt，底部可能越出 6pt。
- 屏幕、Dock 和菜单栏变化后不会主动重新计算内容上限。

建议：

- `show()` 中基于目标 screen 计算 `availableHeight = visibleFrame.height - topMargin - bottomMargin`。
- `position()` 和 `setContentHeight()` 使用同一 clamp helper。
- 屏幕切换只影响当前有效 frame，不持久化高度。
- 测试 470/700pt 宽度以及 600/768/900pt 可用高度。

### 8.3 保留设计令牌，停止无证据微调

当前 Theme 已经集中管理：

- 填充层级。
- 描边。
- 圆角。
- 字体。
- 动效曲线。
- Reduce Motion。
- 面板宽度边界。

这部分的方向是正确的。下一阶段不应再做“把 10.5 改成 10、把 8 改成 7”式无证据调整。

应优先解决：

- 字体是否响应辅助显示需求。
- 英文长文本是否溢出。
- selected/disabled/focus 状态是否清楚。
- 材质叠加是否发灰。
- 窗口与内容动画是否同步。

### 8.4 UI-003：无障碍语义需要系统检查

当前已有的优点：

- DirectionChip 使用真实 Button。
- 多数图标按钮有 accessibility label 和 help。
- Reduce Motion 已集中处理。
- 输入法 marked text 会绕过快捷键拦截。

需要补齐：

- LanguagePill selected trait。
- ToneSelector 当前选中项 trait。
- Pin、History、Profile tab 的 pressed/selected 状态。
- Setting label 使用 `onTapGesture` 并不等价于可键盘操作的 Toggle label。
- Tab 顺序：输入 -> 语言 -> 语气 -> stop/translate -> pin -> history -> settings -> copy。
- VoiceOver 对 interrupted/capped/error/toast 的 live announcement。
- 高对比度下 `.tertiary/.quaternary` 是否仍可读。

### 8.5 UI-004：隐藏滚动条降低溢出可发现性

当前输入、结果、历史和横向语言列表普遍隐藏滚动条。

建议：

- 内容未溢出时保持干净。
- 内容溢出时使用系统 overlay scroller 或明确边缘提示。
- 横向语言列表至少在右侧还有内容时出现克制的边缘指示。
- 不使用渐变遮罩作为装饰；优先系统 scroller、裁切提示或布局重排。

### 8.6 UI-005：材质层级需要真机减法审查

当前层级包括：

- Panel `.popover` NSVisualEffectView。
- Toast `.regularMaterial`。
- Toast shadow。
- Panel 顶部 CAGradientLayer 高光。
- SoftDivider LinearGradient。

这不一定在所有系统外观下都难看，但存在多层折射、发灰和“为了质感而叠质感”的风险。

验收原则：

- 一屏只保留一个主要材质层。
- Toast 如在 Panel 上发灰，改为动态实色半透明表面加系统阴影。
- 顶部高光如果肉眼不可识别价值，直接删除。
- Divider 使用清晰实线 hairline；不要用明显渐变、光晕或发光。
- 深色、浅色、Increase Contrast、Reduce Transparency 分别截图。

### 8.7 UI-006：页面过渡和测高需要逐帧检查

`RootView` 使用 ZStack 和非对称 transition；页面切换期间入场、退场页短暂共存，PreferenceKey 又采用 max height。

可能风险：

- 过渡中窗口沿用较高页面高度，完成时二次收缩。
- 出入页面文本在中段视觉重叠。
- SwiftUI 内容和 AppKit frame 动画不完全同步。
- 首次 show 时 `makeKeyAndOrderFront` 后再把 alpha 设为 0，存在理论上一帧闪现窗口。

这些需要 TUSI_SLOWMO 逐帧验证，而不是单凭代码判断修改。

---

## 9. 本地化审计（UX-010）

英文表目前缺少或疑似缺少以下现行用户文案：

- 本地模型尚未配置，请先在设置中填写。
- 服务器长时间无响应，请稍后重试。
- 服务器长时间未返回新内容，连接已中断，请重试。
- 翻译时使用这个模型。
- 开启后只使用本地模型的两条说明。
- 试听。
- 试听翻译成功音效。
- 部分新增本地模型与状态说明。

建议建立 CI 本地化门禁：

1. 提取 `Text`、`Button`、`Label`、`.help`、`L(...)` 的静态中文 key。
2. 排除 Preview sample、注释和 prompt 内容。
3. 校验 `en.lproj/Localizable.strings` 完整覆盖。
4. 校验格式占位符 `%@/%d` 数量一致。
5. `plutil -lint` 或等价 parser 校验 strings 文件。
6. 为中英文分别运行关键 Preview 场景截图。

本地化测试不能只检查“有 key”，还要检查英文在 470pt 最小宽度下是否被截成无意义省略号。

---

## 10. 测试与 CI 审计

### 10.1 当前覆盖较好的部分

- 混合中英文方向识别。
- 手动翻转方向。
- 多语言目标切换和翻译重启。
- 本地 Profile 独立模式。
- URL 正规化和远程 HTTP 拒绝。
- SSE `[DONE]` 与 `finish_reason`。
- 截断流。
- 首 token 超时。
- 主备 failover 文案。
- 竞速正常 winner。
- 结果原子提交。
- 停止后的部分结果。
- 长输出 cap。
- 历史损坏容错。
- UpdateChecker 基本状态。
- Sound 行为。
- SmartQuotes 多个边界。

### 10.2 关键缺口

- 真实 `URLError` 重试。
- 看门狗 timeout 重试分类。
- idle timeout 测试。
- 竞速先空后成功。
- 流进行中 cap 和上游取消。
- 极细 chunk 的主线程响应。
- 快捷键注册失败后的设置回滚。
- Keychain 各 OSStatus。
- Launch at Login 失败/需要审批。
- 历史恢复截断标记。
- 旧历史加载时的重新限流。
- Clipboard 写入失败。
- 裸 IPv6 `::1`。
- 跨源重定向。
- 本地化完整性。
- 小屏 Settings 可达性。
- VoiceOver 和 Tab 顺序。
- Preview screenshot regression。

### 10.3 测试基础设施风险（ENG-001）

当前存在多个全局 test seam：

- `TranslationService.sessionOverride`
- `TranslationService.firstTokenTimeout`
- `TranslationService.idleTimeout`
- `MockURLProtocol.handler`
- `MockURLProtocol.hangsAfterResponse`

它们依赖 XCTest 当前基本串行。未来并行测试或 Swift Testing 迁移可能相互污染。

建议：

- 把 URLSession、Clock、TimeoutPolicy 注入实例。
- 每个测试创建独立 client 和 URLProtocol state。
- UpdateChecker 注入独立 UserDefaults suite。
- LoginItemService、Clipboard、SoundPlayer 也使用小型协议 seam。
- 禁止测试读写真实 Keychain、真实 UserDefaults domain 和真实 SMAppService。

### 10.4 CI 建议

保留现有 `.github/workflows/ci.yml`，扩展为：

1. 快速 Job：lint/localization/static gates。
2. 单元 Job：`swift test`。
3. 严格构建 Job：当前 release gate。
4. macOS 14 与最新 runner/SDK 兼容矩阵；若 GitHub runner 无法提供真实 macOS 14，至少保留 minimum deployment target 编译并安排真实机发布前验收。
5. 打包复验：
   - arm64/universal 架构。
   - Plist 版本/build。
   - ZIP 无 `__MACOSX`/AppleDouble。
   - codesign strict verify。
   - notarization/stapling（正式发布身份可用时）。

---

## 11. 发布与供应链稳定性

### 11.1 Developer ID 与公证（ENG-003）

当前 README 明确说明应用未公证，用户首次安装可能需要右键 Open。

这是当前最大的安装体验和信任短板。建议发布链路最终支持：

- Developer ID Application 签名。
- Hardened Runtime。
- Apple notarization。
- stapling。
- 解包后的 `spctl --assess`。
- 发布资产校验和。

开发自签名与正式发布签名应分开：

- 本机调试继续使用稳定开发身份以维持 Keychain 授权。
- 正式 Release 必须使用 Developer ID，不把自签名信任状态当成发布完整性。

### 11.2 自动更新边界

当前 UpdateChecker 只打开 GitHub Release 页面，不自动下载或替换应用，安全边界清晰。

短期建议保持现状，先完成公证。以后若引入 Sparkle 或自更新：

- 使用签名 appcast。
- 校验架构资产。
- 原子替换与回滚。
- 不仅比较版本字符串，还验证签名与 bundle identifier。

### 11.3 npm 元数据（ENG-006）

`package.json` 主要用于 `uisfx` 资源来源，但当前存在：

- version 仍为 1.0.0。
- license 为 ISC，而项目 LICENSE 为 MIT。
- `npm test` 固定失败。
- description 仍是早期功能口径。

建议二选一：

1. 如果资源已经合法 vendored 并保留来源/许可证说明，移除非必要 Node 工具链。
2. 如果继续用 npm 管理音频资源，修正 metadata、lockfile 更新规则和资源同步脚本。

---

## 12. 可运维性与隐私诊断（ENG-004）

当前已有 os.Logger 分类，但普通用户遇到问题后仍缺少可直接提供的诊断材料。

建议增加“导出诊断”功能，只包含：

- Tusi 版本/build。
- macOS 版本与架构。
- 当前模式：普通、本地、竞速。
- Profile host 的脱敏域名，不含路径 query。
- 请求阶段耗时：连接、首 token、完整完成。
- 重试次数、是否 failover、是否 race。
- typed error code。
- 更新检查状态。
- Keychain OSStatus（如有）。
- 全局快捷键注册结果。

严禁包含：

- API Key 或 Authorization。
- 输入原文。
- 翻译结果。
- extraInstruction。
- 完整错误响应 body。
- 剪贴板内容。
- 用户目录或其他私有路径。

诊断导出必须是用户主动操作，不做默认远程遥测。

---

## 13. 推荐重构边界（ENG-002）

重构目标不是增加抽象数量，而是把目前容易互相影响的状态域拆开。

### 13.1 TranslationEngine

建议最终边界：

```text
TranslationCoordinator (@MainActor)
  ├─ InputDirectionController
  ├─ TranslationExecutor
  │    ├─ RetryPolicy
  │    ├─ SequentialFailoverPolicy
  │    └─ RacePolicy
  ├─ ResultCommitter
  ├─ HistoryStore
  ├─ ClipboardClient
  └─ FeedbackClient (toast/sound)
```

不要一次性拆完。推荐顺序：

1. 先引入 typed outcome 和测试。
2. 抽出 ProviderAttemptRunner。
3. 抽出 HistoryStore。
4. 抽出 ClipboardClient。
5. 保留 UI-facing ObservableObject 为单一协调器。

### 13.2 SettingsStore

建议逐步拆为：

- ProfileRepository：UserDefaults + Keychain。
- ShortcutStore：快捷键值与 disabled 状态。
- LoginItemService：SMAppService adapter。
- Appearance/BehaviorPreferences：普通布尔设置。

SettingsView 仍只依赖一个 facade，避免在 SwiftUI 中注入过多对象。

### 13.3 PanelController

继续由它拥有 NSPanel 和 AppKit monitors，但可抽出纯函数：

- `PanelFramePolicy`
- `ShortcutResolutionPolicy`

纯策略可在无 GUI 测试中覆盖多屏 frame 和快捷键冲突，不需要重建被否决的持久化 sizing 系统。

---

## 14. 分阶段实施计划

### 批次 0：先建立回归测试，不改变行为

- [ ] 为 TUSI-001 添加真实 URLError 和 timeout 分类测试。
- [ ] 为 TUSI-002 添加先空后成功竞速测试。
- [ ] 为 TUSI-003 添加无限/高频流测试。
- [ ] 为历史截断恢复、快捷键事务和本地化添加失败测试。
- [ ] 记录当前正常翻译、停止、failover、race 的状态序列。

验收：新增测试在当前实现上按预期失败，现有 84 项仍通过。

### 批次 1：后端正确性

- [ ] typed request failure。
- [ ] 修复 retry/failover 判定。
- [ ] 修复 race 空响应。
- [ ] 流进行中 hard cap。
- [ ] 主 actor 外有界聚合。
- [ ] SSE schema/diagnostic 加固。
- [ ] 同源 redirect policy。

验收：

- no-splice 不变量全部通过。
- stop 响应预算通过。
- 1 字符 chunk 压力测试通过。
- 没有 API Key/正文进入日志。

### 批次 2：恢复路径与用户信任

- [ ] 错误类型对应上下文动作。
- [ ] 真实 Translate button。
- [ ] 输入超限持续提示。
- [ ] 历史截断标记、复制和清空撤销。
- [ ] 全局快捷键事务提交。
- [ ] Clipboard 写入结果检查。
- [ ] Keychain typed error。
- [ ] Launch at Login 错误反馈。
- [ ] API Key 隐私文案修正。
- [ ] 本地模型主界面状态。

验收：每个失败状态都有明确恢复路径，不需要用户猜测应打开哪个页面。

### 批次 3：界面稳定性、无障碍与本地化

- [ ] Settings/Shortcuts 小屏滚动。
- [ ] 每次 show 重新 clamp 当前 screen。
- [ ] selected/pressed/accessibility labels 和 Tab 顺序。
- [ ] 溢出时滚动可发现性。
- [ ] 英文本地化补齐和 CI 门禁。
- [ ] 明暗、Reduce Motion、Increase Contrast、Reduce Transparency 验收。
- [ ] 材质层级减法审查。
- [ ] TUSI_SLOWMO 逐帧页面/窗口检查。

验收：所有关键控件在最低宽度和低可用高度下可达，不出现中文漏翻、文字重叠、裁半行或页面底部不可操作。

### 批次 4：结构重构与发布工程

- [ ] ProviderAttemptRunner 实例化。
- [ ] HistoryStore / Clipboard seam。
- [ ] ProfileSlot typed model。
- [ ] 全局静态测试 seam 清理。
- [ ] 脱敏诊断导出。
- [ ] CI 矩阵与包复验。
- [ ] Developer ID / Hardened Runtime / notarization / stapling。
- [ ] package.json 和过期文档治理。

验收：不改变已确认产品行为，正式安装不再需要用户绕过 Gatekeeper。

---

## 15. UI 验收矩阵

每个 UI 批次至少检查：

| 维度 | 场景 |
|---|---|
| 语言 | 简体中文、英文 |
| 外观 | Light、Dark |
| 宽度 | 470pt、700pt |
| 可用高度 | 600pt、768pt、900pt 以上 |
| 系统辅助 | Reduce Motion、Increase Contrast、Reduce Transparency |
| 输入 | 空、1 行、6 行、超 6 行、接近 32k、超限粘贴 |
| 结果 | 等待、短结果、14 行、长结果、停止、cap、失败 |
| 模式 | 普通、fallback、本地、race、多语言 |
| 页面 | Translator、History、Settings 三 Profile、Shortcuts |
| 输入法 | 英文、拼音 marked text、日文输入法 |
| 导航 | 鼠标、Tab、快捷键、VoiceOver |

必须保留的 Preview 场景：

- `main`
- `empty`
- `waiting`
- `settings`
- `settings-local`
- `shortcuts`
- `picker`
- `picker-multi`
- `fallback`
- `racewon`
- `update-available`
- `update-latest`

建议新增：

- `error-auth`
- `error-timeout`
- `error-protocol`
- `history-truncated`
- `input-capped`
- `settings-keychain-error`
- `settings-hotkey-error`
- `result-capped`
- `result-interrupted`

---

## 16. 后端验收不变量

以下规则应直接成为测试名称或断言：

1. 新输入永远不能被旧请求覆盖。
2. 目标语言变化会取消并重启当前翻译。
3. 任一 token 到达后不得 retry 或 failover。
4. 正常翻译期间不发布部分 output。
5. 正常完成只提交一次历史、自动复制和声音。
6. 用户停止只提交单一供应商的部分内容，并标记 incomplete。
7. failed stream 不得留下可复制的半成品。
8. capped stream 主动终止上游，且不自动复制、不播放成功音。
9. race 只接受第一个可用完整结果，不接受第一个空完成。
10. loser 永远不能覆盖 winner 或重复写历史。
11. 用户取消不显示为 timeout。
12. API Key、输入和输出永远不进入日志与诊断。
13. 历史加载后仍满足数量和字段上限。
14. Keychain 读取失败不得自动删除真实凭证。
15. 本地 Profile 永远不进入普通 resolvedChain/race。

---

## 17. 不建议实施的方向

1. 不恢复逐 token UI 输出。
2. 不恢复持久化用户窗口高度。
3. 不恢复原文/译文分割窗。
4. 不用 debounce 动画掩盖数据层逐 token 发布问题。
5. 不在收到 token 后切备用并拼接结果。
6. 不把所有错误都粗暴包装成“网络错误”。
7. 不为“兼容更多本地服务”默认允许远程 HTTP 或任意跨域重定向。
8. 不把 API Key、正文或译文加入远程 telemetry。
9. 不在 P1 行为测试完成前进行大规模目录重构。
10. 不继续依赖肉眼难以区分的 0.5pt/0.01 opacity 微调代替完整工作流优化。

---

## 18. 文档治理（ENG-005）

当前根目录存在多份彼此冲突的方案：

- `AUDIT.md`：基于较早版本，很多问题已经修复。
- `OPTIMIZATION_GUIDE.md`：仍包含“恢复逐字流式输出”等与当前确认行为冲突的建议。
- `MOTION_UI_REDESIGN_PLAN.md`：大部分已实施，但仍属于历史实施计划。
- `TUSI_UI_TRANSLATION_IMPLEMENTATION_SPEC.md`：包含后来明确否决并回滚的持久化窗口高度和分割窗方案。

建议：

- 以本文作为 2026-08-27 当前审计基线。
- 历史方案在标题顶部增加“已过期/仅供历史参考”。
- 不把已明确否决的窗口功能重新交给编码代理实施。
- 每完成一个批次，在本文对应 checkbox 和 issue 状态中更新：
  - Open
  - In Progress
  - Fixed
  - Verified
  - Won't Fix（附产品理由）
- 每个 Fixed 项必须附测试和真实验收证据，不能只写“代码已改”。

---

## 19. 当前源码定位索引

> 以下行号对应 `fe2ec9b`。后续代码变化后应按符号名重新定位，不能机械套用旧行号。

| 领域 | 文件与当前入口 |
|---|---|
| 输入变化与 revision | `Sources/Tusi/Core/TranslationEngine.swift:33` |
| 方向检测协调 | `Sources/Tusi/Core/TranslationEngine.swift:186` |
| 目标语言与模式切换 | `Sources/Tusi/Core/TranslationEngine.swift:237`、`:254`、`:264`、`:273` |
| 翻译主入口 | `Sources/Tusi/Core/TranslationEngine.swift:309` |
| 完整结果提交 | `Sources/Tusi/Core/TranslationEngine.swift:488` |
| 重试执行 | `Sources/Tusi/Core/TranslationEngine.swift:534` |
| 顺序流消费 | `Sources/Tusi/Core/TranslationEngine.swift:587` |
| 竞速 leg 消费 | `Sources/Tusi/Core/TranslationEngine.swift:626` |
| 竞速协调 | `Sources/Tusi/Core/TranslationEngine.swift:660` |
| 用户停止 | `Sources/Tusi/Core/TranslationEngine.swift:709` |
| 剪贴板与反馈 | `Sources/Tusi/Core/TranslationEngine.swift:786`、`:809`、`:817` |
| 历史写入与恢复 | `Sources/Tusi/Core/TranslationEngine.swift:830`、`:848`、`:873`、`:890` |
| 错误定义与 transient 分类 | `Sources/Tusi/Core/TranslationService.swift:4` |
| URL 正规化与 HTTP 安全 | `Sources/Tusi/Core/TranslationService.swift:86` |
| 请求与 Authorization | `Sources/Tusi/Core/TranslationService.swift:154` |
| OpenRouter provider.order | `Sources/Tusi/Core/TranslationService.swift:172` |
| Prompt 和消息边界 | `Sources/Tusi/Core/TranslationService.swift:184`、`:242` |
| 首 token/idle timeout | `Sources/Tusi/Core/TranslationService.swift:254` |
| SSE 执行与解析 | `Sources/Tusi/Core/TranslationService.swift:268` |
| 测试连接 | `Sources/Tusi/Core/TranslationService.swift:403` |
| Profile 与可用性 | `Sources/Tusi/Core/SettingsStore.swift:5`、`:49`、`:73` |
| race/local/声音设置 | `Sources/Tusi/Core/SettingsStore.swift:109`、`:130`、`:151` |
| Launch at Login | `Sources/Tusi/Core/SettingsStore.swift:200` |
| Profile/Keychain 防抖保存 | `Sources/Tusi/Core/SettingsStore.swift:341` |
| resolvedChain | `Sources/Tusi/Core/SettingsStore.swift:474` |
| Keychain 读取/保存/迁移 | `Sources/Tusi/Core/Keychain.swift:26`、`:35`、`:52` |
| Hotkey 注册与回滚 | `Sources/Tusi/HotkeyManager.swift:53`、`:92` |
| App 启动和快捷键订阅 | `Sources/Tusi/AppDelegate.swift:30`、`:73`、`:193` |
| Panel show/hide/position | `Sources/Tusi/PanelController.swift:108`、`:137`、`:146` |
| Panel 内容高度 | `Sources/Tusi/PanelController.swift:174` |
| 局部快捷键与录制 | `Sources/Tusi/PanelController.swift:218`、`:289` |
| Panel resize | `Sources/Tusi/PanelController.swift:352` |
| 翻译页整体布局 | `Sources/Tusi/UI/TranslatorView.swift:137` |
| 输入区/结果区 | `Sources/Tusi/UI/TranslatorView.swift:229`、`:253` |
| 历史区 | `Sources/Tusi/UI/TranslatorView.swift:317`、`:525` |
| 语言选择与底栏 | `Sources/Tusi/UI/TranslatorView.swift:386`、`:450` |
| 设置页整体布局 | `Sources/Tusi/UI/SettingsView.swift:60` |
| 行为设置与 local Profile | `Sources/Tusi/UI/SettingsView.swift:170`、`:276` |
| 更新检查 UI | `Sources/Tusi/UI/SettingsView.swift:415` |
| 通用字段与连接测试 | `Sources/Tusi/UI/SettingsView.swift:642`、`:685` |
| Panel 材质与顶部高光 | `Sources/Tusi/UI/Components.swift:11` |
| 语言/语气/复制控件 | `Sources/Tusi/UI/Components.swift:114`、`:179`、`:226`、`:276` |
| 等待骨架与 Toast | `Sources/Tusi/UI/Components.swift:330`、`:368` |
| 错误框 | `Sources/Tusi/UI/Components.swift:420` |
| 页面切换和高度 Preference | `Sources/Tusi/UI/RootView.swift:12` |
| 设计令牌与动效 | `Sources/Tusi/UI/Theme.swift:17` |
| 语言检测 | `Sources/Tusi/Core/LanguageDetector.swift:160` |
| UpdateChecker | `Sources/Tusi/Core/UpdateChecker.swift:59` |
| SoundPlayer | `Sources/Tusi/Core/SoundPlayer.swift:36`、`:48`、`:63` |
| CI | `.github/workflows/ci.yml:1` |
| 打包/签名/安装 | `build.sh:1` |

---

## 20. 最终结论

Tusi 的核心方向是正确的：原生 macOS、BYOK、可取消 SSE、完成后原子提交、主备防拼接、Keychain 和紧凑面板都值得保留。当前优化的最高回报路径不是增加更多功能，而是把“看起来已经处理”的恢复逻辑变成真实可验证的恢复能力，并补齐用户遇到错误、超长文本、小屏设置、历史摘要和快捷键冲突时的完整闭环。

建议按以下顺序投入：

```text
请求正确性与有界资源
    -> 错误恢复与状态一致性
    -> 小屏/英文/无障碍稳定性
    -> 架构拆分与可诊断性
    -> Developer ID 公证发布
```

完成前两批后，Tusi 的实际可靠性和用户信任会有最明显提升；完成第三、第四批后，项目才具备继续扩展更多供应商、本地后端或更复杂翻译工作流的稳定基础。
