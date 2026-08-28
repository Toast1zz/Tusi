# Tusi 优化实施指南

> 写给另一个 Claude Code 会话：你即将在 `~/Projects/Tusi` 这个文件夹里干活。
> 本文档基于对 v1.8.0 全部源码的通读产生，覆盖用户体验、界面美观/稳定性、后端稳定性三个方向。
> `AUDIT.md` 是之前一份独立审计（Swift 6 并发问题为主，已修复），本文档不重复其内容，两者互补。

## 开工前必读

- 项目是纯 SwiftPM，无第三方依赖：`Package.swift` + `Sources/Tusi/`。
- 构建：`./build.sh`（普通构建）、`./build.sh install --open`（装到 /Applications 并启动，debug 循环用这个）、`./build.sh release`（release 门禁：`-strict-concurrency=complete -warnings-as-errors`，两个架构 zip）。
- 测试：`swift test`，当前 44 个测试全绿，在 `Tests/TusiTests/`。
- UI 自查方式：`TUSI_PREVIEW=main` 或 `TUSI_PREVIEW=settings` 启动会用示例内容把面板钉在打开状态，适合截图检查。改 UI 后必须过一遍明暗两套外观的截图自查，不要只凭代码审查就交付。
- 签名：`build.sh` 会用本机的 `Tusi Dev Signing` 自签名证书签名（钥匙串里应该已经有），不要用 ad-hoc 签名重复安装，否则每次都会因为 cdhash 变化重新弹钥匙串授权。
- 每次改动前 `git status` 确认工作区干净，改完创建有意义的 commit（除非用户说不要提交）。

## 实施顺序（建议按批次推进，每批做完可以独立验收）

### 批次 1：P0 优先级——最大的体验问题

**1. 恢复真·流式输出显示**

- 文件：`Sources/Tusi/Core/TranslationEngine.swift`
- 现状：所有 token 先攒在 `pendingOutput`（第 91 行附近），翻译完成后才一次性提交给 `@Published output`。用户在整个翻译期间只能看骨架屏（`StreamingPlaceholder`），README 却宣称 "Streaming output"——名不符实。
- 为什么当初这么设计：防止 mid-stream 失败后 failover 拼接两个模型的输出。但代码里的规则本来就是「只在首 token 落地前才允许 failover，首 token 之后失败就是终态失败」（`consumeWithRetry` 里对 `pendingOutput` 是否为空的判断）。所以边流边显示并不会引入拼接风险。
- 建议做法：
  - 首 token 到达后开始把内容节流发布到 `output`（可以是现有的攒 buffer 思路，改成每 ~33ms flush 一次，即 30fps），而不是等 stream 完全结束才提交一次。
  - 失败时（`.failed` 分支）清空已发布的 `output`，保持"翻译中失败=看不到半成品"的现有语义不变。
  - `TranslatorView.swift` 里的流式自动滚动（`isAtBottom` 追踪，第 220 行附近）和 `PanelController.swift` 的 `setContentHeight` 里"streaming 时直接 setFrame 不做动画"分支（第 182 行附近）目前是死代码——因为 `output` 在翻译期间从不变化。这两处配套逻辑本来就是为流式显示写的，恢复流式后它们会自动重新生效，不用改。
  - 改完后务必用一个响应慢/输出长的模型（或本地 mock 一个人为加延迟的 stream）手动验证：文字应该逐步出现，面板应该跟手长高，中途停止（stop 按钮）应该正常保留部分内容。

**2. 输入超长静默截断加提示**

- 文件：`Sources/Tusi/Core/TranslationEngine.swift`，`input` 的 `didSet`（第 36 行附近），`maxInputCharacters = 32_000`。
- 现状：粘贴超过 32000 字直接砍掉，用户毫无感知。
- 建议：复用现有的 `Toast` 机制（`enum Toast { case fellBack }`），加一个 `case truncatedInput` 变体，触发时显示"已截断至 32000 字"类似文案。或者更轻量：在输入区下方加一行小字提示，逻辑上更贴近截断这个动作发生的位置。

**3. 清理陈旧注释**

- 恢复流式显示后，回头检查 `PanelController.swift` 的 `setContentHeight` 注释、`TranslatorView.swift` 里 `isAtBottom` 相关注释，确认它们描述的行为和新代码一致。这个库的注释质量本身是资产，别留下失真的注释。

---

### 批次 2：小而明确的 bug / 死功能

**1. API Key 字段焦点高亮缺失**

- 文件：`Sources/Tusi/UI/SettingsView.swift`，第 98 行附近的 `labeledField("API Key", ...)` 调用。
- 问题：其他三个字段（接口地址、模型、供应商路由）调用 `labeledField` 时都传了 `focused:` 参数，唯独 API Key 这处没传；而且 `.focused($focusedField, equals: .apiKey)` 挂在外层 `HStack` 上，不在实际的 `TextField`/`SecureField` 上，焦点绑定大概率没生效。
- 修复：把 `focused: focusedField == .apiKey` 传给 `labeledField` 调用（对齐另外三处的写法），并确认 `.focused()` modifier 直接挂在文本输入控件上。改完后聚焦这个字段应该和另外三个一样出现 accent 描边。

**2. 钥匙串"已保存"确认是死代码，激活或删除**

- 文件：`Sources/Tusi/Core/SettingsStore.swift`，`keychainSaved`（`@Published private(set) var keychainSaved`，带 250ms 防抖 + 1.6s 自动消失的完整实现）。
- 现状：这个状态在任何 View 里都没被读取，纯粹的死代码。
- 建议：在 `SettingsView.swift` 的 API Key 字段旁（`showKey` 切换按钮附近）加一个小的 ✓ 图标，`keychainSaved == true` 时短暂显示，做输入 API Key 后"确实存进钥匙串了"的反馈。如果决定不做这个功能，就把 `keychainSaved` 相关的发布属性和防抖逻辑删掉，不要留着不用的状态机。

**3. 输入截断提示**——同批次 1 第 2 条，可以一起做。

---

### 批次 3：后端稳定性

**1. 流中途停滞缺看门狗**

- 文件：`Sources/Tusi/Core/TranslationService.swift`，`stream(...)` 函数（第 259 行附近），现有的 `firstTokenTimeout` 看门狗。
- 问题：看门狗只保护"首 token 迟迟不来"这一种情况。首 token 之后如果服务器卡住不再发送任何 chunk，唯一的兜底是 `productionSession` 的 300 秒 resource timeout——用户会盯着骨架屏（或者恢复流式后，盯着停滞的半截文字）5 分钟。
- 建议：把看门狗改成逐 chunk 空闲计时——每收到一个 chunk 就重置一次计时器（现有的 `gotData.withLock { $0 = true }` 那行旁边顺带记录/刷新一个时间戳），空闲超过某个阈值（建议 45 秒）就按超时处理，复用现有的 `didTimeOut` + 取消逻辑。

**2. `[DONE]` 缺失一律判定为"截断"过于严格**

- 文件：同上，`stream(...)` 里 `guard sawDone else { throw TranslationError.truncatedStream }`（第 337 行附近）。
- 问题：部分 OpenAI 兼容网关/ 自建代理会在发完内容后干净关闭连接而不发送 `[DONE]` 哨兵。当前这些场景会被误判成"翻译结果不完整"，还会触发一次重试，浪费一次完整请求。
- 建议：给 `StreamChunk` 增加 `finish_reason` 字段的解码（在 `choices[].finish_reason`），收到 `finish_reason == "stop"`（或非 null）的 chunk 时也标记为正常完成，不必强制要求同时收到 `[DONE]`。两者有其一即可判定完成。

**3. 补最小 CI**

- 项目没有 `.github/` 目录。`build.sh` 本地已经有 `-strict-concurrency=complete -warnings-as-errors` 门禁和 44 个测试，但只在本地跑，没有 PR 层面的强制检查。
- 建议：加 `.github/workflows/ci.yml`，macOS runner 上跑 `swift test` + `./build.sh`（走 release 门禁路径），设为 PR 必过检查。这是把现有代码质量锁住的最便宜手段，实施成本很低，优先级可以往前提。

**4. 历史写入最坏情况在主线程**

- 文件：`Sources/Tusi/Core/TranslationEngine.swift`，`saveHistory()`（第 638 行附近）。
- 现状：同步顺序写文件，注释解释了为什么必须同步（防止乱序覆盖、防止应用退出时写入被打断）——这个理由是对的，不要推翻它去做异步写。
- 问题：最坏情况下 50 条记录 × (32k 输入上限 + 64k 输出上限) ≈ 10MB JSON，主线程编码+写盘会有可感知卡顿。
- 建议：不改变"同步写"这个决策，而是限制单条记录进历史时的体积——比如 `pushHistory` 存档时把 input/output 各截断到 4000 字左右再写入 `Record`（面板内当次的完整 input/output 不受影响，只是历史归档变短），这样把最坏情况的文件体积和编码耗时钉死在一个可预期范围内。

---

### 批次 4：视觉系统化（一次改完，统一过明暗两套外观截图验收）

**1. 历史列表行高硬编码估算**

- 文件：`Sources/Tusi/UI/TranslatorView.swift`，`historyViewportHeight`（第 250 行附近）：`28 + count * 86` 里的 86pt 是估出来的魔法数。
- 项目里已经有过 CJK 测高踩坑的教训（中英文行高不同，字号一改就可能裁半行）。这个文件里 `inputHeight`/`height(lines:)` 已经用 AppKit `boundingRect` 做精确测量，`historyViewportHeight` 应该复用同一套测量方式，而不是拍脑袋的常数。

**2. 面板宽度边界值散落四处，收敛进 Theme**

- `470` / `700` 这两个数字出现在 `PanelController.swift` 的 init、`windowWillResize`、`windowDidResize`，以及 `SettingsStore.swift` 第 200 行附近的持久化读取里。挪成 `Theme.panelMinWidth` / `Theme.panelMaxWidth`，四处改成引用同一个来源。

**3. 填充不透明度收敛成语义 token**

- 全项目搜一遍 `Color.primary.opacity(...)`，会看到 0.025 / 0.05 / 0.055 / 0.06 / 0.065 / 0.07 / 0.08 / 0.09 / 0.12 / 0.14 这十档数字，散落在 `Components.swift`、`SettingsView.swift`、`TranslatorView.swift` 各处，很多是相近但不完全相同的值（比如 0.055 和 0.06 大概率是想表达同一个语义状态，只是不同时间写的不同人/不同心情调的）。
- 在 `Theme.swift` 里新增 4–5 个语义化 token，比如：
  ```swift
  static let fillQuiet = Color.primary.opacity(0.05)      // 静态背景填充（字段、badge）
  static let fillHover = Color.primary.opacity(0.065)     // hover 态
  static let fillActive = Color.primary.opacity(0.09)     // active/pressed 态
  static let strokeHairline = Color.primary.opacity(0.08) // 描边、分隔线
  ```
  然后把各处调用替换成对应 token。这是让界面读起来像"一个系统的产物"而不是"每个控件自己调的灰"的关键一步——用户对 UI 美观极其挑剔，对标 Raycast 质感，这条直接影响观感一致性。
- **改完必须过明暗两套外观的截图自查**，因为 opacity 数值的视觉效果在深色模式下和浅色模式下不是线性对应的，合并相近数值可能在某一套外观下产生肉眼可见的变化。

**4. 尊重"减弱动态效果"系统设置**

- 现在所有动画无条件运行（`Theme.snappy` 在 `TUSI_SLOWMO` 环境变量下才会变慢，跟系统设置无关）。
- 建议：读取 `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`，为真时让 `Theme.snappy` 返回极短时长或 `.linear(duration: 0)`。这个应用动画点很多（页面推入、pill 滑动、面板伸缩、toast 弹出），对开启了该辅助功能选项的用户来说，不遵守是持续的骚扰。

**5. 超高内容时面板可能越界屏幕**

- `PanelController.swift`：`panel.maxSize` 高度上限 2000pt，`position()` 只钳制了 x 方向，没钳制高度。小屏幕（比如 13 寸外接投影）叠加 14 行结果 + 6 行输入 + 底栏的极端情况下，面板底部可能超出可视区域。
- 建议在 `setContentHeight` 里，用 `screen.visibleFrame.height` 给最终高度封顶。

**6. DirectionChip 键盘不可访问**

- `Components.swift` 第 158 行附近：用 `onTapGesture` 而非 `Button` 实现点击，加了 `.accessibilityAddTraits(.isButton)` 但键盘 Tab / VoiceOver 实际无法激活它。改成 plain-style `Button` 包裹相同视觉内容，行为对齐，视觉不变。

---

### 批次 5：功能增强（节奏自定，优先级最低，可以放最后或按用户反馈再排）

**1. 历史功能补全**（`TranslatorView.swift` 的 `historyList` 区域）
   - 清空历史目前一键即清、不可撤销（`Button("清空历史")` 直接调 `engine.clearHistory()`）。加二次确认（按钮点第一次变成"确认清空？"再点一次生效）或者 3 秒内可撤销的 toast。
   - 50 条记录没有搜索/过滤，加一个轻量输入框按 input/output 内容过滤。
   - 单条历史记录现在必须先点击"恢复"到主输入区才能复制，加一个 hover 时露出的行内复制按钮。

**2. 多语言模式的目标语言选择挪到主面板**
   - 现在目标语言网格在 `SettingsView.swift` 里（第 188 行附近），但这是一个翻译时的高频动作，不该埋在设置页。
   - 建议：点击 `DirectionChip` 时在主面板内联展开语言网格（不要用 popup ——代码里已有的注释解释了 popup 会让面板 resign key 从而触发点击外部自动隐藏，这个坑之前应该已经踩过）。

**3. 降低首次配置门槛**
   - Base URL / 模型名目前全靠手打。README 里点名了 DeepSeek / OpenRouter / SiliconFlow / Ollama 几个常见服务，可以在接口地址字段下加对应的快捷填充 chip，点一下自动填 base URL + 占位模型名。BYOK 本质不变，只是省打字。

**4. 更新提醒可见性**
   - 现在有新版本时只在右键菜单里一行字。可以在菜单栏图标上加一个极小的 badge 点（模板色渲染，不能太抢眼），设置页齿轮入口同步一个点。

**5. 常见错误直达设置**
   - 401 / 402 / 429 这几类错误的文案已经写得很清楚了，但用户看到错误后还得自己去找该改哪个 profile。`ErrorBox` 组件在这几类错误时加一个"去设置"按钮，直接打开对应的 profile 页（用现有的 `panelState.showSettings = true` + `panelState.settingsProfileIndex` 定位到出问题的那个 slot）。

---

## 其他值得注意但不急的点

- `TranslatorView.swift` 里 `inputMeasureCache` 是 View struct 上的 `static var` 可变缓存，没有显式 actor 隔离标注。实际只在主线程访问，风险很低，但和 `AUDIT.md` 里修过的那批 Swift 6 并发问题是同一类。改动时顺手标 `@MainActor`，并确认 `swift build -Xswiftc -strict-concurrency=complete` 仍然零警告（`build.sh release` 门禁已覆盖，但日常 `build.sh install` debug 循环容易漏掉这项检查，记得偶尔手动跑一次 release 门禁）。
- `windowDidResize` 拖拽调宽时每个 resize tick 都会经 `settings.panelWidth` 的 `didSet` 写一次 `UserDefaults`。无实际危害，但没必要，可以改成只在 `windowDidEndLiveResize` 时写一次。
- `HotkeyManager` 的 Carbon 回调理论上有一个析构竞态窗口（回调在任意线程触发，`deinit` 移除 handler 之前存在极小的窗口期），但因为这个对象和 App 同生命周期、永不中途析构，实际风险为零。建议只加一行注释声明这个前提（"依赖 App 生命周期，不得中途重建"），防止未来重构时有人为了别的目的提前释放它。
- 测试补强方向：`SmartQuotes` 的 CJK 嵌套引号 + 未配对反引号边界情况、`sanitizeModelOutput` 的 HTML 实体混合场景、`LanguageDetector` 对日文纯汉字句（无假名时会被判定为中文——这是已知的取舍，建议写一个测试把这个行为钉住，避免以后被误当 bug 改掉）、以及基于 `TUSI_PREVIEW` 的截图回归测试（每个 preview 场景截一张图，人工或脚本 diff）。

## 验收方式提醒

- 每一批 UI 相关改动做完后：`TUSI_PREVIEW=main` 和 `TUSI_PREVIEW=settings` 分别过一遍，明暗两套系统外观（System Settings ▸ Appearance 切换）各截一张图，肉眼确认没有引入新的不一致。
- 每一批改动做完后跑 `swift test`，确认现有 44 个测试仍然全绿；涉及 `TranslationService`/`TranslationEngine` 的改动（尤其是批次 1 流式显示、批次 3 的看门狗和 `[DONE]` 判定）建议补充对应的新测试用例，而不是只手动验证。
- release 门禁 `./build.sh release` 建议在批次 3、4 做完后各跑一次，尽早发现并发/警告问题，而不是攒到最后一起排查。
