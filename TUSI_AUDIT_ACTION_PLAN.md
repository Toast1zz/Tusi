# Tusi 修复执行清单（给 Sol）

> 来源：`TUSI_COMPLETE_CODE_AUDIT_2026-08-27.md`（Codex 审计），已由 Claude 逐条核对代码后精简。
> 规则写在最前面，照做，不要跳步、不要一次改多处、不要自己发挥。

## 铁律

1. **一次只做一个任务**。做完一个任务的"验收步骤"全部通过，再开始下一个。
2. **每个任务做完，必须跑**：
   ```bash
   swift build && swift test
   ```
   现在是 84 个测试全过。如果任务写了"新增测试"，跑完应该是 84+N 个全过。少一个都不算完成。
3. **不要重命名、不要挪文件、不要"顺手"重构没让你动的代码**。只改任务里点名的地方。
4. **任务里没提到的建议（原审计报告第 13 节的架构拆分、BE-004 的 actor 拆分）一律不要做**，本清单末尾会说明原因。
5. 改完一个任务，写一句话说明改了什么、测试结果，不用写长总结。

---

## 任务 1（先做，别的都依赖它）：给瞬时错误加一个统一判断点

✅ 完成于 2026-08-27，测试 88 个全过。

**问题**：[TranslationService.swift:41](Sources/Tusi/Core/TranslationService.swift:41) 的 `isTransient` 只认 `.http(code >= 500)` 和 `.truncatedStream`。但看门狗超时抛出的是 `.http(0, message)`（见 [TranslationService.swift:367](Sources/Tusi/Core/TranslationService.swift:367) 和 `:417`），`0 >= 500` 是 false，所以超时永远不会重试。真实的 `URLError`（断网、DNS 失败、连接重置）更是直接透传给调用方，根本不是 `TranslationError`，同样永远不重试。

**改法**（不要重新设计一套新 enum，只在现有基础上补）：

1. 在 `TranslationError` 里新增一个 case，专门表示"看门狗超时"，和 HTTP 状态码 0 区分开：
   ```swift
   case watchdogTimeout(stage: String)  // stage: "first-token" 或 "idle"
   ```
   把 [TranslationService.swift:367](Sources/Tusi/Core/TranslationService.swift:367) 和相邻的 `:417` 处原本抛 `.http(0, ...)` 的两处，改成抛这个新 case（各自传对应的 stage 文案）。
2. `isTransient` 里加一条：
   ```swift
   case .watchdogTimeout(let stage):
       return stage == "first-token"   // 首 token 超时可重试；已经在收数据后又 idle 超时，说明连接本来就不稳，同样可重试——直接给 true
   ```
   实际上两种 stage 都应该返回 `true`（超时都值得重试一次），不需要区分，写成：
   ```swift
   case .watchdogTimeout:
       return true
   ```
3. 在 [TranslationEngine.swift:563](Sources/Tusi/Core/TranslationEngine.swift:563) 附近，`consumeWithRetry` 判断 `transient` 的地方，改成同时接住 `URLError`：
   ```swift
   let transient: Bool
   if let te = error as? TranslationError {
       transient = te.isTransient
   } else if let ue = error as? URLError {
       // 网络层面的瞬时失败：超时、连接丢失、DNS 失败、TCP 重置
       transient = [.timedOut, .networkConnectionLost, .cannotFindHost,
                    .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet]
                    .contains(ue.code)
   } else {
       transient = false
   }
   ```

**验收**：在对应的测试文件里加 4 个测试（找现有测试文件里测 `consumeWithRetry` / retry 的地方，抄它的写法）：
- 首次收到 `URLError(.timedOut)`，第二次成功 → 最终结果是成功译文。
- 首次收到 `URLError(.networkConnectionLost)`，第二次成功 → 同上。
- 首 token 看门狗超时，第二次成功 → 同上。
- 用户主动取消（cancel）时，不应该走到任何"超时重试"的分支，结果必须是 `.cancelled`，不能被误判成 transient。

跑 `swift test`，确认新测试全过，且已有 84 个不受影响。

---

## 任务 2：修复竞速模式被空响应误杀

✅ 完成于 2026-08-27，测试 92 个全过。

**问题**：[TranslationEngine.swift:688-694](Sources/Tusi/Core/TranslationEngine.swift:688)，`raceForFastest` 里任何一条 leg 一旦 `.completed`（哪怕内容是空的），立刻 `group.cancelAll()` 并返回失败——不会等另一条可能成功的 leg。

**改法**：把 [TranslationEngine.swift:687-705](Sources/Tusi/Core/TranslationEngine.swift:687) 这段循环改成：

```swift
var firstError: Error?
var sawEmpty = false
while let (index, outcome) = await group.next() {
    switch outcome {
    case .completed(let buffer):
        self.pendingOutput = buffer
        let usable = self.commitPendingOutput(text: text, source: source, sourceLabel: sourceLabel, target: target, tone: tone)
        if usable {
            group.cancelAll()
            return (.succeeded, index)
        }
        // 这条 leg 完成但内容是空的：不取消另一条，继续等它
        sawEmpty = true
    case .cancelled:
        group.cancelAll()
        return (.cancelled, nil)
    case .failed(let error):
        firstError = firstError ?? error
        // 继续等待另一条腿
    }
}
// 两条腿都跑完了，没有一条给出可用内容
if sawEmpty { return (.emptyResponse, nil) }
return (.failed(firstError ?? TranslationError.emptyResponse), nil)
```

注意：`commitPendingOutput` 在 `usable == false` 时已经会把 `pendingOutput` 清空（看它的实现，[TranslationEngine.swift:496-499](Sources/Tusi/Core/TranslationEngine.swift:496)），所以不用你手动清。

**验收**：新增 5 个测试（竞速相关的测试文件里，抄现有 race 测试的 mock 写法）：
- leg A 先返回空、leg B 后返回正常内容 → 最终结果是 B 的内容，`.succeeded`。
- leg A 先失败、leg B 后成功 → 结果是 B 的内容。
- leg A 先返回空、leg B 后失败 → 结果是失败（不是空响应，因为好歹有一个明确错误，保留这个错误更有诊断价值）。
- 两条都返回空 → 结果是 `.emptyResponse`。
- 两条都失败 → 结果是失败。
- 额外检查：赢家提交后，输家的回调不能再次写历史或覆盖 `output`（用现有的"loser 不能覆盖 winner"测试模式抄一份）。

跑 `swift test` 确认通过。

---

## 任务 3：历史加载后重新套用容量上限

✅ 完成于 2026-08-27，测试 93 个全过。

**问题**：[TranslationEngine.swift:890-901](Sources/Tusi/Core/TranslationEngine.swift:890) `loadHistory()` 解码成功后直接 `history = decoded`，不会重新应用"最多 50 条、单字段最多 4000 字"的限制。旧文件、手工改过的文件可以带着超大数据进来。

**改法**：在 `loadHistory()` 里，`history = decoded` 和 `history = lossy?.compactMap(\.record) ?? []` 这两行之后，都过一遍归一化：

```swift
private func normalizeLoadedHistory(_ records: [Record]) -> [Record] {
    records
        .prefix(50)  // 用现有的历史条数上限常量，别写死数字，找一下 pushHistory 里限制条数用的那个常量名并复用
        .map { record in
            var r = record
            if r.input.count > Self.historyFieldCharacterLimit {
                r.input = String(r.input.prefix(Self.historyFieldCharacterLimit))
            }
            if r.output.count > Self.historyFieldCharacterLimit {
                r.output = String(r.output.prefix(Self.historyFieldCharacterLimit))
            }
            return r
        }
}
```

把 `history = decoded` 改成 `history = normalizeLoadedHistory(decoded)`，另一处同理。

**注意**：`Record` 现在是不是 `let` 属性（immutable）要先看一下 struct 定义，如果字段是 `let` 就改不了，需要在 `map` 里用 memberwise init 重新构造一个新 `Record`，别改 `Record` 的属性可变性（那是任务 4 要动的地方，不要在这里顺手改，避免一次改两个任务的东西）。

**验收**：加一个测试——手工构造一个 60 条记录、其中某条 input 有 10000 字的 JSON 文件，写到临时路径，触发加载，断言最终 `history.count <= 50` 且每条 input/output 都 `<= 4000`。

跑 `swift test` 确认通过。

---

## 任务 4：历史截断要老实标注，不能显示成"完整结果"

✅ 代码与自动化测试完成于 2026-08-27，测试 94 个全过；真机截图验收待执行。

**问题**：[TranslationEngine.swift:115](Sources/Tusi/Core/TranslationEngine.swift:115) 历史归档字段限制 4000 字，但截断后恢复到界面时状态是 `.done`，跟正常完整结果没有任何区别标记。用户可能把截断的半成品当全文复制走。

**改法**：
1. 给 `Record` 加两个字段：`inputTruncated: Bool`、`outputTruncated: Bool`，默认值 `false`（这样旧的历史 JSON 解码时这两个新字段用 `Decodable` 默认值兜底，不会炸）。
2. 在写入历史的地方（`pushHistory`，大概在 [TranslationEngine.swift:830](Sources/Tusi/Core/TranslationEngine.swift:830) 附近），如果 `input.count > historyFieldCharacterLimit` 才截断，截断时把 `inputTruncated` 设成 `true`；`output` 同理。
3. 在 `TranslatorView.swift` 里显示历史行的地方（[TranslatorView.swift:317](Sources/Tusi/UI/TranslatorView.swift:317) 附近的历史列表），如果 `record.outputTruncated == true`，在这一行加一个小图标或文字标记（例如一个 `"…"` 或 `scissors` SF Symbol），并且 `.help()` 提示"历史仅保留部分内容"。
4. 恢复历史到主界面时（找 `restoreHistory` 相关函数），如果任一 truncated 为 true，状态仍然是 `.done`，但同时要能让 UI 知道要显示不完整提示——最简单做法：不新增 `.done` 之外的状态，而是在 `TranslatorView` 里判断"当前显示内容是否来自一条 truncated 历史"，用一个独立的 `@Published var restoredFromTruncatedHistory: Bool` 记录，恢复时设置，用户重新编辑输入时清空。界面上有这个 flag 为 true 时，在结果区顶部加一行小字提示，别改动 `state` 枚举本身（改枚举会牵连很多 switch，风险大）。

**验收**：
- 新增测试：写入一条 output 超过 4000 字的记录，断言存进去的 `Record.outputTruncated == true` 且 `output.count == 4000`。
- 新增测试：正常长度的记录，`outputTruncated == false`。
- 手动在应用里验证（用 `TUSI_PREVIEW` 或直接跑 app）：造一条超长翻译，看历史行是否出现标记、点开后是否有不完整提示。截图发给用户确认，不要自己判定"看起来对了"就算完成。

---

## 任务 5：加一个真正能点的翻译按钮

✅ 代码与自动化测试完成于 2026-08-27，测试 94 个全过；鼠标与 VoiceOver 真机验收待执行。

**问题**：[TranslatorView.swift:478-483](Sources/Tusi/UI/TranslatorView.swift:478) 现在是一个 disabled 的静态 `Text("⏎ 翻译")`，鼠标点不了，VoiceOver 读不出"按钮"。

**改法**：把这段：
```swift
} else if !engine.input.isEmpty && engine.output.isEmpty {
    Text("⏎ 翻译")
        .font(Theme.footnoteMedium)
        .foregroundStyle(.tertiary)
        .transition(.opacity)
}
```
换成一个真 `Button`：
```swift
} else {
    Button {
        engine.translate()   // 用现有触发翻译的方法名，去 TranslatorView 里搜 Return 键调用的是哪个方法，抄那个名字，不要猜
    } label: {
        Text("翻译")
            .font(Theme.footnoteMedium)
    }
    .buttonStyle(.plain)   // 或者找 BarIconButton 一类现成样式抄，保持视觉和其它按钮一致
    .disabled(engine.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    .foregroundStyle(engine.input.isEmpty ? .tertiary : .primary)
    .transition(.opacity)
}
```
**注意**：
- 不要删掉 Return 快捷键，这个按钮是"新增一个可点击入口"，不是替代键盘操作。
- 按钮的宽度不要因为文案变化（"⏎ 翻译" 4 字 vs "翻译" 2 字）导致底栏跳动——改完后目测一下这一块尺寸有没有明显跳动，如果有，给 `Text` 加固定宽度或者用 `.fixedSize()`。

**验收**：跑 `run` 技能或手动 `swift build` 后启动 app，鼠标点这个按钮能触发翻译；VoiceOver 打开后 Tab 到这里，读出"翻译，按钮"而不是普通文字。截图/录屏确认，不要只凭代码判断就说完成。

---

## 任务 6：设置页在矮屏幕下要能滚动

✅ 2026-08-28 已按“自然高度测量 + 可用高度 clamp + 内容滚动”重新实现；Settings/Shortcuts 均使用滚动容器，RootView 通过 `PanelHeightKey` 报告内容高度，PanelController 在小屏幕上限制窗口高度。自动化布局测试通过；真机截图和 VoiceOver 操作仍需在可用桌面会话中补验。

**问题**：`SettingsView.swift` 整页是一个裸 `VStack`（[SettingsView.swift:61](Sources/Tusi/UI/SettingsView.swift:61)），没有 `ScrollView`。`PanelController` 会把窗口高度限制在屏幕可用高度内，超出的内容会被圆角 mask 直接裁掉，用户够不到。

**改法**：在 `SettingsView` body 最外层，把现在的 `VStack(alignment: .leading, spacing: 14) { ... }`（第 61 行那个）包一层：
```swift
ScrollView {
    VStack(alignment: .leading, spacing: 14) {
        // 原来的内容不动
    }
}
```
`ShortcutsView` 如果也是同样结构（没有 ScrollView），一并处理。

**注意**：
- 不要给 ScrollView 加自定义滚动条样式、渐变遮罩之类的装饰，用系统默认的就行。
- 不要改动 `PanelController` 里高度计算的逻辑，这个任务只管 SwiftUI 内容层能不能滚，不管窗口本身多高。

**验收**：用 `mcp__Claude_Browser` 或直接跑 app，把窗口移到一个可用高度很小的场景（可以用 iOS Simulator 工具里没有对应功能，需要手动改测试代码模拟，或者直接问用户能不能在外接小分辨率屏幕/或用 `resize_window` 之类的方式验证）——**如果实在没法在这个环境里模拟矮屏幕，如实告诉用户"这一项需要真机在小屏幕上验收，我没法在当前环境验证"，不要编造"已验证"**。

---

## 任务 7（简单，可以插空做）：三个一行能改完的问题

✅ 完成于 2026-08-27，Swift 构建与测试 94 个全过，package.json 解析和英文 strings 校验通过。

这三个不用分别开任务，可以在同一次改动里一起做（因为互相独立、改动都很小、风险低）：

**7a. 剪贴板写入要检查返回值**
[TranslationEngine.swift:786](Sources/Tusi/Core/TranslationEngine.swift:786) 附近，`NSPasteboard...setString` 调用现在忽略了返回的 `Bool`。改成：
```swift
let ok = pasteboard.setString(text, forType: .string)
if ok {
    flashCopied(auto: auto)
} else {
    // 显示一个短暂的失败提示，具体用现有 toast 机制，别新建一套
}
```

**7b. API Key 隐私文案改准确**
在 `SettingsView.swift` 和 `Localizable.strings`（含 en.lproj）里搜 "不会上传" 或 "仅保存在本机钥匙串"，把文案改成：
> "API Key 仅保存在本机钥匙串，只发送给你配置的 API 服务"

英文版对应改成语义一致的版本，不要机翻，读起来要像人话。

**7c. package.json 元数据**
`version` 改成和 app 当前版本一致（去 Xcode 项目或 `build.sh` 里找当前版本号，抄过来，不要瞎写）；`license` 从 `ISC` 改成 `MIT`（和仓库 LICENSE 一致）；如果 `npm test` 目前就是占位、项目根本不用 npm 跑测试，把这行删掉或者改成 `"test": "swift test"`，二选一，别都不动。

**验收**：`swift build && swift test` 照常跑；另外拿 `plutil` 或直接 `node -e "require('./package.json')"` 确认改完的 `package.json` 是合法 JSON。

---

## 明确不要做的事（原报告里提的，你不用管）

- **不要**引入 `TranslationCoordinator` / `ProviderAttemptRunner` 这类新 actor 层来"把每个 token 挪出主线程"（原报告 BE-004、第 13.1 节）。这是没有实测数据支撑的推测性优化，先别碰。如果以后真的实测到卡顿（比如任务 1-6 做完后，手动灌一个高频 mock 流测试，发现停止按钮响应变慢），再单独立项。
- **不要**做 `SettingsStore` 拆成 `ProfileRepository`/`ShortcutStore`/`LoginItemService` 四件套（原报告 13.2 节）。现在的 `SettingsStore` 能用，这种拆分对当前项目规模是过度设计。
- **不要**做 `ProfileSlot` / `ProfileSet` 的类型改造（原报告 BE-009）。裸下标目前没出过事故，这是"以后可能有用"的债务，不是现在的问题。
- **不要**去搞 Apple Developer ID 签名/公证流程（原报告 ENG-003）。这需要付费开发者账号，是否投入这笔钱是用户的商业决定，不是代码任务，等用户明确说要做再做。
- 任务 1 里提到的统一错误 enum，**不要**照抄原报告里那个大而全的 `RequestFailure`（带 `retryAfter`、`ConfigurationFailure`、`ProtocolFailure` 一堆嵌套 case）。只加够用的东西，多了没人维护。

---

## 完成顺序

严格按 1 → 2 → 3 → 4 → 5 → 6 → 7 的顺序做，每完成一项在这份文件对应标题后面加一行 `✅ 完成于 <日期>，测试 N 个全过`。不要并行开好几个任务同时改，容易互相踩文件冲突。

## 三轮执行复审记录（2026-08-28）

1. 第一轮：修复瞬时网络错误重试、竞速空响应、历史容量归一化、历史截断标记、可点击翻译入口、设置页滚动和基础体验问题。
2. 第二轮：复审第一轮改动并补齐进行中输出上限、精确上限标记、SSE finish-only/畸形 payload 处理、跨源重定向凭证隔离。
3. 第三轮：复审第二轮改动并补齐输入截断持久反馈、Tone/Language/Profile 选中语义和原生 Toggle 无障碍控件。

最终证据：`swift test` 共 109 项测试全部通过；严格并发与 warnings-as-errors 构建通过；英文 `L(...)` 键 74/74 覆盖；release 使用 `Tusi Dev Signing` 签名并验证；`/Applications/Tusi.app` 为 `1.11.3 (34)`，运行中仅有一个实例。
