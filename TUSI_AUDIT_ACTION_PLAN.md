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

## 任务 8：译文语言不符时必须警告，不能当成正常结果

✅ 已由 Claude 直接实现并完成于 2026-08-28，测试 113 个全过（新增 4 个），`./build.sh release` 严格并发门禁通过。**Sol 不用做这一条**，但要读懂下面的取舍，后续别改坏。

**问题来源**：真机截图发现，输入「真的吗，你们的回答好官方。」方向是「中 → EN」，但结果区显示的是中文的「是的，感谢您的反馈。」——模型把输入当成一句吐槽**回复**了，而不是翻译，而且用错了语言。界面把这个结果当成正常成功结果展示，还会自动复制进剪贴板。

[TranslationService.swift:212](Sources/Tusi/Core/TranslationService.swift:212) 的 system prompt 其实已经写了 "never answer or explain it"，但模型没遵守。**结论：prompt 层的约束不是保证，必须在结果侧兜一道。**

**已实现的改动**（4 处）：

1. [LanguageDetector.swift](Sources/Tusi/Core/LanguageDetector.swift) 新增 `looksLikeWrongLanguage(_:target:)`，以及配套的 `isHanLetter`（`isHan` 的去标点版本）。
2. [TranslationEngine.swift](Sources/Tusi/Core/TranslationEngine.swift) 新增 `@Published private(set) var outputLanguageMismatch`，在 `commitPendingOutput` 里计算，命中时**保留文本**但抑制自动复制与成功音（复用 `outputCapped` 那套 `cleanCompletion` 语义）。
3. [TranslatorView.swift](Sources/Tusi/UI/TranslatorView.swift) 结果区新增橙色警告条，排在 `interrupted` / `outputCapped` **之前**（语言错说明整条结果无效，比"怎么结束的"更严重）。
4. system prompt 末尾补一句强制输出语言、且明确"即使原文读起来像在问你话，也要翻译不要回答"。

**关键设计取舍（改之前必须理解，不然很容易改坏）**：

- **为什么是警告不是报错**：`LanguageDetector.detect` 有三个已知误判倾向——认不出来时默认返回中文、纯汉字日文判成中文、Latin 词多的中文判成英文。做成硬错误的话，一次误判就把**正确的译文丢掉**并让用户白烧一次 API。保留文本 + 显式警告，误判的代价只是一条多余提示。
- **为什么不是 `detect(output) != target` 这种写法**：那正是上面误判会集中爆发的写法。实际实现只认**脚本级铁证**（目标是非 CJK 语言却输出大段 CJK 等），并且 6 字符以下一律不判。
- **为什么用户主动停止的部分结果不判**：半截文本判语言不可靠，`cancelTranslation` 路径不设这个标志。
- **为什么恢复历史不判**：历史是用户当初已经接受过的译文，没必要翻旧账。

**顺带修掉的英文布局 bug（既有问题，不是任务 8 引入的）**：截图验收英文界面时发现，底栏在英文下整体超出 470pt 面板宽度——`ToneSelector` 和 `CopyButton` 都带 `.fixedSize(horizontal: true)`（"1.11.3 防止底栏换行"那次提交加的），谁都不肯压缩，而 [RootView.swift:43](Sources/Tusi/UI/RootView.swift:43) 把内容钉死在 `panelWidth`，于是整块内容被居中后**左右双向裁切**：输入框左边的字、底栏的「中」、右边的「⌘C」全被切掉。对照实验（英文 + 正常译文、不含警告条）确认同样复现，所以是既有 bug。

**实测数字**（用临时打点量的，已移除打点）：底栏含左右 16pt 边距，中文需要 **461.5pt**，英文需要 **523.5pt**。`Theme.panelMinWidth` 是 470——中文够、英文差 53.5pt，这就是英文裁切的直接原因。`PanelController` 顶部原有一条注释说「英文量到 428.5pt」，那其实是**中文**的数字，写错了，也是 470 这个值当初被误判为够用的原因。

**修法（宽度改为内容驱动，与高度对称）**：高度一直是内容驱动的（`PanelHeightKey` → `setContentHeight`），宽度不是。现在补上同构的一套：

1. [RootView.swift](Sources/Tusi/UI/RootView.swift) 新增 `PanelContentWidthKey`。
2. [TranslatorView.swift](Sources/Tusi/UI/TranslatorView.swift) 用一份**隐藏的、不受约束的**底栏副本测出它真正需要的宽度（含 16pt 边距）并上报。副本固定按「最宽形态」渲染（始终带复制按钮和快捷键提示），否则窗口会随着开始/结束翻译左右跳动。
3. [PanelController.swift](Sources/Tusi/PanelController.swift) 新增 `contentMinWidth` 与 `effectiveWidth = clamp(max(用户宽度, 内容所需), 470, 700)`，并把 `panel.minSize.width` 抬到内容所需宽度——这样**用户手动拖拽也不可能拖到裁切**。两处 resize 回调的下限同步改用 `contentMinWidth`。

结果：中文窗口维持 470（无变化），英文自动变宽到 523.5 且 `Copy ⇧⌘C` 完整显示。用户自己拖宽的偏好不会被覆盖，只是不允许低于内容所需。

`ViewThatFits` 保留作为兜底（内容需求超过 700pt 上限或屏幕过窄时才会降级），正常情况下不会触发。任务 5 那个翻译按钮的 `.frame(width: 48)` 也改成了 `.frame(height: 26).frame(minWidth: 48)`——硬宽 48pt 会把英文 "⏎ Translate" 切掉。

**别把这套改回"直接调大 `panelMinWidth`"**：那是让所有语言、所有用户为最宽的那个本地化买单；内容驱动才能让每种语言各取所需。新增本地化时也不用再手工量宽度。

**这个方案抓不到什么（别以为修完就万无一失）**：如果模型用**正确的目标语言**回了一句闲聊（例如目标英文、回了句英文的 "Sure, thanks for the feedback."），任何廉价检测都抓不住。那属于模型指令遵循问题，只能靠 prompt 缓解。**不要**为了追这种情况去加"语义相似度""回译校验"之类的二次模型调用——成本和延迟翻倍，收益不确定。

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

任务 8 由 Claude 直接实现，不占用 Sol 的执行顺序。

## 三轮执行复审记录（2026-08-28）

1. 第一轮：修复瞬时网络错误重试、竞速空响应、历史容量归一化、历史截断标记、可点击翻译入口、设置页滚动和基础体验问题。
2. 第二轮：复审第一轮改动并补齐进行中输出上限、精确上限标记、SSE finish-only/畸形 payload 处理、跨源重定向凭证隔离。
3. 第三轮：复审第二轮改动并补齐输入截断持久反馈、Tone/Language/Profile 选中语义和原生 Toggle 无障碍控件。

最终证据：`swift test` 共 109 项测试全部通过；严格并发与 warnings-as-errors 构建通过；英文 `L(...)` 键 74/74 覆盖；release 使用 `Tusi Dev Signing` 签名并验证；`/Applications/Tusi.app` 为 `1.11.3 (34)`，运行中仅有一个实例。

## 第四轮：清掉审计里剩下的条目（2026-08-29）

前三轮之后，`TUSI_COMPLETE_CODE_AUDIT_2026-08-27.md` 第 5 节里仍未处理的条目已全部过一遍。除了本清单末尾明确"不要做"的那几项（BE-004、BE-009、ENG-002、ENG-003），处理结果如下：

| ID | 处理 |
|---|---|
| UX-002 | 错误框不再只有"重试"。新增 `FailureKind`（`Core/Diagnostics.swift`），按失败原因决定主动作：未配置/凭证/地址问题 → "打开设置"（本地模型未配置直接跳到本地槽），瞬时错误 → "重试"。次动作固定为"复制诊断"。 |
| UX-003 | 输入接近上限时（还剩 4,000 字）显示剩余字数；超限后的持久提示保持不变。计数刻意来得晚——它是警告不是仪表盘。 |
| UX-005 | 无修饰键的字母/数字快捷键不再"先绑定再警告"，改为 `PanelState.pendingBareShortcut` 挂起 + 快捷键页二次确认；离开页面或重新录制都视为放弃。判定逻辑抽成 `PanelController.needsBareKeyConfirmation` 以便测试。 |
| UX-006 | 本地模型模式在底栏显示一个 `desktopcomputer` 标记，tooltip 给出模型名与 host（不给完整 URL）。只用图标：底栏是宽度关键行。 |
| UX-010 | 新增测试 `testEveryChineseUIStringHasAnEnglishTranslation`：扫描 `Sources/Tusi` 里所有含汉字的字符串字面量，要求 en.lproj 有对应条目。顺带补上了它查出来的 4 条真实缺失（本地模型开关那组文案 + "试听翻译成功音效"）。 |
| UX-011 | 设置页音效开关下新增系统 Slider（开启音效时才出现），拖动结束后 220ms 试听一次。此前 `soundVolume` 只能持久化、无法修改。 |
| UX-012 | "供应商路由" → "供应商优先顺序"，文案讲明只是 OpenRouter 的偏好顺序、仍可能回退到未列出的供应商。README 同步。 |
| UX-013 | 检测器的三处已知取舍（纯汉字日文判成中文、只看前 400 字、无信号回落中文、Han/Latin 打平判非中文）写成 `testDetectorTradeOffsAreDeliberateAndPinned`，改坏时测试会响。 |
| BE-008 | Keychain 错误按 OSStatus 分流：设备锁定 / 访问被拒 / 签名变化 / 暂不可用各有各的说法和补救，其余保留错误码。新增 `isTemporary`，设置页对可重试的失败给出"重试"按钮；`retryLoadKeys()` 成功后清掉过期的错误提示（此前解锁后提示会一直挂着）。 |
| UI-004 | 输入框、结果区、历史列表的 `.scrollIndicators(.never)` 改为 `.automatic`：macOS 的 overlay scroller 只在真的能滚时出现，不溢出时界面完全不变。没有加渐变遮罩。 |
| ENG-004 | 新增 `Diagnostics`：应用/系统版本、各槽 host 与模型、模式开关、目标语言、失败原因，**不含** API Key、原文、译文和完整 base URL（路径可能带私有 token）。入口有两个：错误框的"复制诊断"，以及设置页底部的"复制诊断信息"。 |
| ENG-005 | `AUDIT.md`、`OPTIMIZATION_GUIDE.md`、`MOTION_UI_REDESIGN_PLAN.md`、`TUSI_UI_TRANSLATION_IMPLEMENTATION_SPEC.md` 顶部加状态横幅（已过期 / 已实施 / 部分否决），并指向当前基线。README 修掉三处与实际不符的描述：仍写着"流式输出"（实际是一次性提交）、"两个 profile"（实际三槽）、供应商路由口径。 |
| BE-005 / BE-006 / BE-010 / BE-011 / UI-002 / UX-007 / UX-008 / UX-009 | 复核代码后确认前三轮已实现，本轮未改。 |

证据：`swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 通过；`swift test` 123 项全过（第三轮 109 → 本轮 +14）；`node -e "require('./package.json')"` 通过。

**仍需真机验收（本轮没有 GUI 会话，没有截图，不算已验证）**：
- UI-005（材质层级发灰）、UI-006（页面过渡与二次测高）需要在真机上逐帧看，属于"看"的问题，代码层面无从判定。
- 本轮新增的界面元素——底栏本地模型标记、错误框两个动作在英文下的换行、音量 Slider、快捷键二次确认条、overlay scroller 的观感——都只做了布局尺寸测试，没有肉眼确认。离屏渲染（NSHostingView + cacheDisplay）试过，材质和次级文字渲染不出来，不足以当验收证据。
- 任务 4/5/6 遗留的截图验收同样仍未执行。
