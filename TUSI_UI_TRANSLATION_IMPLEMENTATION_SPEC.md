# Tusi 翻译交互与可调整窗口实施规格

> **状态：部分否决，仅供历史参考。** 其中的持久化窗口高度与原文/译文分割窗方案已被明确否决并回滚，不要重新实施；结果一次性展示的部分已经落地。
> 当前基线是 [TUSI_COMPLETE_CODE_AUDIT_2026-08-27.md](TUSI_COMPLETE_CODE_AUDIT_2026-08-27.md)。

> 本文档用于交给编码 AI 直接实施。开始前必须重新检查当前工作树和相关源码；不得只按本文中的行号机械修改。本文是需求与验收标准，当前代码是实现事实来源。

## 1. 目标

本次只解决以下三项体验问题：

1. 重新规划翻译过程中右下角复制按钮的状态，保留当前初始状态和翻译完成状态。
2. 允许用户从窗口底部向下拉长 Tusi；窗口变高后，可拖动原文与译文之间的分割线来分配两块区域的高度。
3. 统一本地模型和在线模型的展示节奏：翻译期间持续显示等待骨架，完整结束后一次性显示全部译文，不再逐字刷新本地模型结果。

## 2. 不在本次范围内

- 不改变翻译提示词、语言检测、目标语言切换、语气选择或模型配置。
- 不改变 OpenAI-compatible API 协议，不把请求改成 `stream: false`。
- 不重做整个底栏、设置页或历史页的视觉设计。
- 不改变窗口宽度现有的 470–700 pt 范围。
- 不发布版本、不创建 GitHub Release，除非用户后续明确要求。
- 不使用渐变、光晕、厚重磨砂或非原生装饰来表现进度和分割线。

## 3. 当前实现与问题根因

### 3.1 复制按钮

相关文件：

- `Sources/Tusi/UI/TranslatorView.swift`
- `Sources/Tusi/UI/Components.swift`
- `Sources/Tusi/Core/TranslationEngine.swift`

当前底栏行为：

- `engine.isTranslating == true` 时显示独立的停止按钮。
- 复制按钮是否出现只取决于 `engine.output.isEmpty`。
- 流式响应收到第一个片段后，`output` 立即变为非空，所以翻译尚未结束时复制按钮会突然出现。
- 这会造成底栏中途重新排布，并允许用户复制尚未完成的译文。

### 3.2 窗口高度

相关文件：

- `Sources/Tusi/PanelController.swift`
- `Sources/Tusi/UI/RootView.swift`
- `Sources/Tusi/UI/TranslatorView.swift`
- `Sources/Tusi/Core/PanelState.swift`
- `Sources/Tusi/Core/SettingsStore.swift`

当前窗口虽然包含 `.resizable`，但 `PanelController.windowWillResize` 会把高度强制改回 `desiredHeight`，因此实际上只能改变宽度。`setContentHeight` 又持续根据 SwiftUI 内容高度重设窗口，用户高度与自动高度没有区分。

原文和译文目前分别有固定的行数上限，中间的 `SoftDivider` 只是装饰线，不具备分割视图行为。

### 3.3 本地模型逐字显示

相关文件：

- `Sources/Tusi/Core/TranslationService.swift`
- `Sources/Tusi/Core/TranslationEngine.swift`
- `Sources/Tusi/UI/TranslatorView.swift`

本地和在线服务实际都通过 OpenAI-compatible SSE 接收数据。差异来自服务端返回节奏：本地服务往往快速、细粒度地发送 token；部分在线服务会在服务端缓冲较长时间。

`TranslationEngine.consumeStream` 当前约每 33ms 把缓冲片段追加到已发布的 `output`，因此本地模型明显逐字刷新。这个差异应在 Tusi 的展示提交层统一，而不是根据 host 写两套 UI。

## 4. 最终交互规格

### 4.1 翻译与复制按钮状态表

| 状态 | 译文区域 | 停止按钮 | 复制按钮 |
|---|---|---:|---:|
| 初始、无结果 | 保持当前输入界面 | 隐藏 | 隐藏 |
| 正在翻译、尚无 token | 显示现有等待骨架 | 显示 | 隐藏 |
| 正在翻译、后台已有部分 token | 仍显示等待骨架，不显示部分译文 | 显示 | 隐藏 |
| 正常完成 | 一次性显示完整译文 | 隐藏 | 显示当前蓝色“复制”按钮 |
| 自动复制或手动复制成功 | 完整译文保持不变 | 隐藏 | 使用当前绿色“已复制”状态 |
| 用户停止且已有部分内容 | 停止后一次性显示部分译文，并显示“已停止，结果不完整” | 隐藏 | 显示，可复制部分内容 |
| 用户停止但尚无内容 | 回到无结果状态 | 隐藏 | 隐藏 |
| 失败 | 丢弃未完成缓冲并显示当前错误框 | 隐藏 | 隐藏 |

硬性规则：

- 正常翻译过程中不得发布任何部分译文到 UI。
- 正常翻译过程中不得出现复制按钮。
- 不新建“翻译中复制按钮”、禁用复制胶囊或额外进度胶囊。
- 继续使用现有 `StreamingPlaceholder` 表达等待，不叠加第二套 spinner。
- 停止仍是独立操作，不把复制按钮变形成停止按钮。
- 完整译文和复制按钮应在同一次状态提交中出现，避免先出文字、后出按钮的额外跳动。

### 4.2 本地与在线模型统一展示

所有 provider 使用同一套行为，不依据 `localhost`、`127.0.0.0/8`、`::1`、API Key 是否为空或模型名称分支 UI。

底层仍使用 SSE 流式接收，原因包括：

- 保留首 token 超时检测。
- 用户可以立即停止请求。
- 能继续判断某次请求是否已收到部分内容。
- 已收到部分内容后不得切换备用服务，避免把两个模型的译文拼接在一起。

展示层改为：

1. 每个 SSE 片段进入未发布的内部缓冲区。
2. 请求正常结束并通过 revision/cancellation 校验后，统一做 Smart Quotes、长度限制和完整性处理。
3. 最终文本一次性赋给公开的 `output`，随后切换到 `.done`。
4. 自动复制、成功提示音和历史记录只能在这次完整提交之后发生。

### 4.3 用户停止、失败与重启语义

- 用户点击停止：
  - 如果内部缓冲非空，立即取消网络任务，把已收内容一次性提交为 `output`，应用 Smart Quotes，设置 `interrupted = true` 和完成态，不写成“完整结果”。
  - 如果内部缓冲为空，回到 idle。
- 输入被编辑、语言被切换或新翻译启动：取消旧任务并丢弃旧缓冲，不得把旧缓冲显示出来。
- 请求失败：未发布的部分内容必须丢弃；维持当前错误表现。
- 某个 provider 已产生任意 token 后失败：不得尝试备用 provider，即使这些 token 从未展示给用户。
- 只有在当前 provider 一个 token 都没有产生且错误满足现有 transient 条件时，才允许当前 provider 重试或切换备用服务。
- `inputRevision` 和现有 cancellation guard 必须继续阻止旧请求覆盖新请求。

## 5. 建议的数据结构与引擎改造

以下是建议，不要求逐字照抄命名，但行为必须等价。

### 5.1 增加未发布缓冲

在 `TranslationEngine` 中增加主线程隔离、非 `@Published` 的内部字段，例如：

```swift
private var pendingOutput = ""
```

要求：

- `translate()` 开始新请求时清空。
- 每个新 provider attempt 开始前按现有重试语义清空。
- `clearResult()`、输入变化和语言重启路径清空。
- 正常完成后先读取并提交，再清空。
- 普通失败后清空。
- 用户停止时允许先提交已有缓冲，再清空。

### 5.2 不再按 33ms 发布 UI

现有 `consumeStream` 的 33ms flusher 不再向 `self.output` 追加内容。可以直接把片段追加到 `pendingOutput`，或让 `StreamConsumeOutcome` 携带累计文本。

无论采用哪种方式，都必须保留以下信息：

- 是否收到过 token。
- 完整累计内容。
- 是正常结束、失败还是取消。
- 当前 request revision 是否仍有效。

不要用固定延迟、debounce 到数百毫秒或动画遮盖逐字刷新；必须从数据发布层真正做到只提交一次。

### 5.3 UI 防御性条件

即使引擎保证翻译时 `output` 为空，UI 仍应写出明确语义：

- `engine.state == .translating` 时始终显示 `StreamingPlaceholder`。
- 复制按钮条件至少包含 `!engine.isTranslating && !engine.output.isEmpty`。

这样以后引擎内部变化也不会重新引入翻译中复制按钮。

## 6. 可拉伸窗口规格

### 6.1 基本行为

- 用户可拖动窗口底边向下拉长或向上缩短。
- 拖动底边时窗口顶部保持在原位置，不得上下跳动。
- 宽度继续限制在 470–700 pt，并保持当前宽度持久化逻辑。
- 高度最小值是当前页面能够完整展示关键控件的自然高度，不允许压住底栏或让原文/译文区域消失。
- 高度最大值应根据当前屏幕 `visibleFrame` 动态计算，并预留顶部与底部边距；不要继续使用与屏幕无关的 2000 pt 作为实际可达高度。
- 用户手动设置的翻译窗口高度跨隐藏/重新打开及应用重启保存。
- 第一次运行或从未手动改过高度时，保持当前自动紧凑高度。

### 6.2 自动高度与用户高度必须分离

至少区分：

- `naturalContentHeight`：当前页面在紧凑模式下所需的自然高度。
- `preferredTranslatorHeight`：用户最后一次完成 live resize 后选择的翻译页高度，可选且持久化。
- `effectiveHeight`：在当前屏幕范围内，取能够容纳自然内容且尊重用户高度的结果。

建议规则：

```text
effectiveHeight = clamp(
    max(naturalContentHeight, preferredTranslatorHeight ?? naturalContentHeight),
    lower: naturalContentHeight,
    upper: screenAvailableHeight
)
```

实现要求：

- 程序根据内容变化调整窗口时，不得误写成新的用户偏好。
- 使用 `windowWillStartLiveResize` / `windowDidEndLiveResize` 或等价机制区分用户 live resize 与程序化 `setFrame`。
- 用户偏好只在手动 resize 结束时持久化，避免拖动过程中高频写 `UserDefaults`。
- 内容自然高度增加并超过当前窗口时，可以自动向下增长以防裁切。
- 内容自然高度减少时，如果已有用户高度，不要自动缩回紧凑高度。
- 尚无用户高度时，继续保留现有内容驱动的紧凑自动伸缩体验。
- SwiftUI 的高度测量必须测到自然内容高度，不能把已拉伸后的 hosting view 总高度回报为自然高度，否则会形成尺寸反馈循环。

### 6.3 页面切换

- 手动高度偏好属于翻译页面。
- 设置页和快捷键页继续采用各自自然高度，不显示翻译分割线，也不覆盖翻译页保存的高度。
- 从设置页返回翻译页时恢复翻译页的用户高度。
- 历史页可以使用翻译窗口的额外垂直空间，但不显示原文/译文分割线。

## 7. 原文/译文分割线规格

### 7.1 结构

当当前页面为翻译页且存在译文区域时，原文和译文应放入真正的纵向 split view。优先使用 macOS 原生能力：

- SwiftUI `VSplitView`；或
- 为了可靠绑定/持久化位置而桥接 `NSSplitView`。

不要仅给 `SoftDivider` 加一个未经约束的 `DragGesture` 来伪造 split view，除非能够完整实现原生 resize cursor、命中区、最小尺寸、键盘可访问性和窗口 resize 协同。

### 7.2 视觉与交互

- 分割线视觉保持克制、接近现有细线，不增加渐变、发光或厚重手柄。
- 可见线可以很细，但实际鼠标命中区应足够宽，避免难以抓取。
- hover/drag 时使用 macOS 上下调整尺寸光标。
- 拖动向上：给译文更多空间；拖动向下：给原文更多空间。
- 原文区和译文区都必须有合理最小高度，底栏始终固定在窗口底部且不参与分割。
- 分割位置用 0–1 的比例或等价稳定值保存，并在窗口高度变化后重新计算。
- 对保存值进行 clamp，不能让某一侧恢复后低于最小高度。
- 用户第一次拉长且尚未设置分割位置时，多余空间默认约 35% 分配给原文、65% 分配给译文。

### 7.3 紧凑与拉长状态

- 窗口处于自然紧凑高度时，视觉应与当前版本尽量一致。
- 拉长后，原文 `TextEditor` 和译文 `ScrollView` 使用新增空间，不再停留在 6 行/14 行的固定视觉上限。
- 内容仍可分别滚动。
- 拖动分割线只改变两个文本 viewport 的高度，不改变底栏位置和窗口总高度。
- 没有译文区域时不显示分割线；原文区可以使用可用空间，但不制造空的译文 pane。

## 8. 持久化建议

在 `SettingsStore` 中增加明确、可 clamp 的持久化值，例如：

- `preferredTranslatorHeight: CGFloat?`
- `translatorSplitFraction: CGFloat`

在 `PanelState` 中保存当前运行时尺寸和页面布局状态。注意：

- preview/test 使用现有隔离的 UserDefaults suite，不得污染真实用户设置。
- 旧版本没有这些 key 时必须自然回退到当前紧凑布局。
- 不需要迁移脚本；读取不存在的 key 时使用默认值即可。
- 屏幕变化、Dock/Menu Bar 变化或从大屏切到小屏时，每次显示前重新 clamp。

## 9. 预计修改文件

| 文件 | 预计职责 |
|---|---|
| `Sources/Tusi/Core/TranslationEngine.swift` | 未发布缓冲、一次性提交、停止/失败/重试语义 |
| `Sources/Tusi/UI/TranslatorView.swift` | 翻译态始终骨架、复制按钮条件、可扩展双 pane 布局 |
| `Sources/Tusi/UI/Components.swift` | 如有需要，增加原生 split view bridge 或轻量视觉适配 |
| `Sources/Tusi/PanelController.swift` | 纵向 live resize、顶部锚定、自然高度与用户高度协调、屏幕 clamp |
| `Sources/Tusi/Core/PanelState.swift` | 当前窗口高度、分割位置及页面运行时状态 |
| `Sources/Tusi/Core/SettingsStore.swift` | 高度和分割位置持久化 |
| `Sources/Tusi/UI/RootView.swift` | 正确区分自然高度测量和拉伸后的可用高度 |
| `Sources/Tusi/PreviewSupport.swift` | 增加等待、长原文/长译文、拉长窗口的视觉预览场景 |
| `Tests/TusiTests/TusiTests.swift` | 引擎缓冲、取消、失败、重试、旧流防串写及尺寸策略测试 |

如果能用一个独立、纯逻辑的 `PanelSizingPolicy` 或等价 helper 表达尺寸 clamp，优先这样做，便于单元测试；不要把所有规则散落在 delegate 回调里。

## 10. 必须新增或更新的自动化测试

### 10.1 翻译提交

1. 连续 yield 多个 chunk 后，在 stream 完成前：
   - `state == .translating`
   - `output.isEmpty == true`
2. stream 完成后：
   - `output` 一次性等于所有 chunk 拼接结果
   - `state == .done`
3. 用户在已有 chunk 时停止：
   - 一次性显示已有内容
   - `interrupted == true`
   - 内容可由 `copyOutput()` 复制
4. 用户在首 token 前停止：回到 idle 且无 output。
5. 中途收到 chunk 后发生错误：
   - 不展示部分结果
   - 不尝试备用 provider
   - 显示失败状态
6. 首 token 前 transient failure：继续符合现有重试/备用逻辑。
7. 翻译中切换目标语言或多语言模式：旧缓冲不得覆盖新请求。
8. 修改输入后旧流晚到：不得发布旧缓冲。
9. 超长输出仍按 `maxOutputCharacters` 截断并标记 `outputCapped`。
10. 自动复制和成功音效只在完整、未截断结果提交后触发。
11. 本地无 API Key 的现有测试继续通过。

### 10.2 窗口与分割位置

至少把尺寸计算抽成可测试逻辑，并覆盖：

1. 没有保存高度时使用自然高度。
2. 保存高度大于自然高度时使用保存高度。
3. 自然高度后来超过保存高度时使用自然高度。
4. 高度不超过当前屏幕可用高度。
5. 程序化内容调整不写入用户高度。
6. live resize 结束后写入用户高度。
7. 分割比例恢复时同时满足两侧最小高度。
8. 从大屏切换到小屏后高度与分割位置均能安全 clamp。

## 11. 真实运行与视觉验收

仅有 `swift test` 或编译成功不足以证明完成。必须在真实 macOS 窗口中验证。

### 11.1 功能验证

- 在线 provider：等待骨架持续到结束，结果一次性出现。
- 本地 loopback provider：行为与在线一致，不逐 token 刷新。
- 翻译期间复制按钮始终不出现。
- 完成时译文和复制按钮一起出现。
- 有内容后停止：部分结果一次性出现并标记不完整。
- 无内容时停止：不留下空译文区域。
- 语言切换、输入修改和连续快速发起翻译无旧结果串写。
- 备用服务、首 token 超时和失败提示没有回归。

### 11.2 窗口验证

- 从底边拉长时顶部稳定。
- 拉长后底栏固定在底部，文本区域吃到额外空间。
- 分割线容易抓取，拖动方向符合直觉，两侧不能被压没。
- 原文和译文各自滚动正常，文字选择正常。
- 隐藏再打开、重启应用后，高度和分割位置按规格恢复。
- 从大屏移动到小屏后窗口不会超出屏幕。
- 设置页、快捷键页、历史页切换无尺寸跳动、空白异常或分割线残留。

### 11.3 视觉验证

使用 `TUSI_PREVIEW` 的隔离模式增加必要场景，并至少检查：

- 浅色模式和深色模式。
- 紧凑高度和明显拉长后的高度。
- 长原文、长译文、两者都长。
- 翻译等待态、完成态、用户停止态。
- 窗口圆角、阴影和边缘在 live resize 期间不闪烁、不变方。

## 12. 推荐实施顺序

1. 先为 `TranslationEngine` 增加失败中的测试，覆盖“完成前 output 为空、完成后一次提交”。
2. 实现内部缓冲，保持重试、备用服务、取消和 revision 语义。
3. 收紧 `TranslatorView` 的等待态与复制按钮条件。
4. 抽出并测试窗口尺寸策略。
5. 修改 `PanelController`，允许纵向 live resize 并区分程序化和用户 resize。
6. 引入原生纵向 split view，接入高度与分割位置持久化。
7. 增加 preview 场景，进行真实窗口、浅色/深色和本地/在线端到端验证。
8. 最后运行完整测试和构建，检查 `git diff`，确认没有范围外改动。

## 13. 完成定义

只有同时满足以下条件才可声称完成：

- 三项用户需求全部实现，不是只修改表面动画。
- 正常翻译过程中没有部分译文和复制按钮。
- 本地、在线模型均为等待后一次性展示完整结果。
- 底层 SSE、取消、重试、备用服务和旧流防串写规则均保留。
- 窗口可从底边实际拉长，顶部稳定。
- 原文/译文分割线可实际拖动，两侧内容可独立查看和滚动。
- 用户窗口高度与分割位置能安全持久化并在不同屏幕上 clamp。
- 自动化测试、构建和真实窗口视觉/交互验收均通过。
- 未进行未经授权的安装、发布或远程操作。
