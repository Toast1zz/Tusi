# Tusi 动画与 UI 系统重构方案

> 写给执行本方案的 Claude Code 会话：你将在 `~/Projects/Tusi`（纯 SwiftPM，无第三方依赖）里干活。
> 本文档基于对 v1.11.0 全部 UI 源码（64 处动画调用点、Theme.swift 全部 token）的逐点审读产生。
> 本文是需求与验收标准；当前代码是实现事实来源，行号会漂移，动手前先重新定位。

## 开工前必读

- 构建：`./build.sh`；调试安装 `./build.sh install --open`；发布门禁 `./build.sh release`（`-strict-concurrency=complete -warnings-as-errors`，双架构）。
- 测试：`swift test`，当前 84 个全绿。每批做完必须跑。
- UI 自查：`TUSI_PREVIEW=main|settings|settings-local|picker|racewon|waiting` 启动会把面板钉在对应状态；`TUSI_DARK=1` 不存在——深浅色靠系统外观切换，明暗两套都要截图。
- 动画自查：`TUSI_SLOWMO=1` 会把动画放慢 10 倍逐帧看。**注意：当前它只对走 `Theme.snappy()` 的调用点生效，批次 M1 完成前它看不到大部分动画——这本身就是要修的 bug 之一。**
- 铁律（都是踩过坑立的）：
  - 面板内**永远不用 popover/menu**——弹出会让 panel resign key，触发点击外部自动隐藏。
  - 不要恢复逐字流式显示；结果一次性原子提交的契约不能动。
  - 签名用本机 `Tusi Dev Signing`，别 ad-hoc。
  - 改完 UI 必须明暗两套外观截图肉眼验收，不能只靠代码审查。

---

## 第一部分：动画哲学（为什么现在不对）

Tusi 的定位是 Spotlight/Raycast 式的效率面板。这类原生工具的动画共识：

1. **工具面板的 chrome 动画不带弹跳。** 弹簧过冲（overshoot）属于"直接操纵"场景——手指拖拽、可甩动的卡片。折叠、翻页、开关、面板伸缩是"状态切换"，应该是**纯减速（ease-out）**：快速启动、平滑停住、绝不回弹。macOS 系统自己的 Spotlight、菜单、popover 全是这样。
2. **短。** 高频操作的动画每天被看几百次。悬停 ≤120ms，状态切换 ≤180ms，布局变化 ≤220ms，页面推入 ≤280ms。超过 300ms 的只允许出现在装饰性循环（骨架屏脉冲）。
3. **一次状态变化 = 一条时间线。** 折叠展开时，chevron 旋转、内容出现、窗口长高必须读成"同一个动作"，而不是三件事先后发生。
4. **弹簧只留给一个地方**：ToneSelector 的滑动药丸（matchedGeometryEffect）。滑块从 A 滑到 B 是有质量感的位移，允许极轻微弹性——这是全应用唯一合法的 spring。

### 现状的三个系统性缺陷

**缺陷 A：`.snappy` 用错了场合。**
SwiftUI 的 `.snappy` 是带 ~0.15 bounce 的弹簧。全项目约 40 处用它做 chrome 动画（折叠 chevron、页面推入、toast、toggle 布局）。用户抱怨的"设置里折叠展开弹跳效果不好"就是它。

**缺陷 B：两套 API 并存，辅助功能适配是漏的。**
`Theme.snappy(d)`（会检查 Reduce Motion 和 TUSI_SLOWMO）与裸 `.snappy(duration: d)`（什么都不检查）混用。grep 统计：TranslatorView / SettingsView 的绝大多数调用点用的是**裸版本**——意味着此前加的"尊重减弱动态效果"实际只覆盖了少数几处，SLOWMO 调试同样只覆盖少数几处。这是必须修的正确性问题，不是风格问题。

**缺陷 C：双时间线打架。**
窗口高度由 PanelController 的 `NSAnimationContext`（AppKit，easeOut 0.25s）驱动；内容由 SwiftUI 驱动。两条时间线曲线不同、无法对齐，代码里现有注释承认了这一点，并用 `.transition(.identity)`（内容瞬间弹出、只让窗口滑动）来回避。结果就是折叠展开的实际观感：**chevron 带弹跳地转，内容凭空闪现，窗口再用另一条曲线追着长高**——三件事三个节奏。修法不是继续回避，而是让两边用同一条数学曲线（见批次 M2）。

---

## 第二部分：新动画系统设计

### 2.1 Theme 动机 token（替换现有 duration + snappy）

删掉 `Theme.snappy(_:)` 和四个裸 duration 常量的直接暴露，改为**语义化动机 token**。核心技巧：曲线用一组 cubic-bezier 控制点定义一次，同时生成 SwiftUI `Animation` 和 AppKit `CAMediaTimingFunction`，两条时间线从源头上就是同一条曲线。

```swift
// Theme.swift — 全部替换现有 Animation 区块
enum Theme {
    // 唯一的标准减速曲线：快出缓停，无回弹。
    // 同一组控制点喂给 SwiftUI 和 AppKit，双时间线从根上对齐。
    private static let curve: (Double, Double, Double, Double) = (0.2, 0.8, 0.3, 1.0)

    static var caTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(curve.0), Float(curve.1), Float(curve.2), Float(curve.3))
    }

    /// 所有动画唯一入口。Reduce Motion → 时长归零；TUSI_SLOWMO → ×10。
    private static func motion(_ duration: Double) -> Animation {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return .linear(duration: 0)
        }
        return .timingCurve(curve.0, curve.1, curve.2, curve.3, duration: duration * animationScale)
    }

    // 语义 token —— 调用点只允许用这五个，不允许再写裸 .snappy/.easeOut/duration 字面量。
    static var microMotion: Animation { motion(0.12) }     // 悬停、图标微交互
    static var stateChange: Animation { motion(0.18) }     // 开关、chevron、选中态、toast 出现
    static var layoutChange: Animation { motion(0.22) }    // 折叠展开、行增减、面板高度（AppKit 侧用同曲线同时长）
    static var pageTransition: Animation { motion(0.28) }  // 翻译页↔设置页↔快捷键页
    /// 全应用唯一合法弹簧：ToneSelector 滑动药丸。
    static var selectionSlide: Animation {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return .linear(duration: 0) }
        return .spring(duration: 0.3 * animationScale, bounce: 0.15)
    }

    static let layoutChangeDuration: Double = 0.22  // PanelController 的 AppKit 侧引用
}
```

要点：
- Reduce Motion 归零逻辑只写在 `motion(_:)` 一处，永远不可能再漏。
- `animationScale`（TUSI_SLOWMO）同理只写一处。
- `layoutChangeDuration` 单独暴露给 PanelController，配 `caTimingFunction`，保证窗口和内容同曲线同时长。
- 迁移完成后加防回归门禁：在 CI（`.github/workflows/ci.yml`）加一步
  `! grep -rn "\.snappy(\|\.easeOut(\|\.easeInOut(\|withAnimation(\.\|\.spring(" Sources/Tusi/UI Sources/Tusi/*.swift --include="*.swift" | grep -v Theme.swift | grep -v StreamingPlaceholder`
  （骨架屏脉冲豁免，见 2.3）。grep 规则可以自己调，目标是：**Theme.swift 之外不允许出现任何裸动画曲线**。

### 2.2 全部 64 处调用点的迁移映射

机械替换，按语义归类（行号以当前 v1.11.0 为准，动手前重新 grep）：

| 现状 | 换成 | 调用点 |
|---|---|---|
| `Theme.snappy(Theme.durationFast)` / 裸 `.snappy(Fast)` | `Theme.microMotion` | Components 悬停×3、SettingsView keychainSaved / shortcutsRowHovering、TranslatorView HistoryRecordRow hover |
| 裸/包装 `.snappy(Standard)` 用于开关、选中、chevron、toast、testState、updateChecker.state | `Theme.stateChange` | Components DirectionChip×4 / CopyButton、SettingsView 折叠按钮×2 / slotTab / 设为主用 / raceFastest / testRow / update 状态、ShortcutsView×2、TranslatorView picker 开关/收起×2 |
| 用于行/区域增减、面板内容高度联动的 | `Theme.layoutChange` | TranslatorView `hasResultSection` / `showHistory` / `showLanguagePicker` / toast 的 ambient `.animation`、bottomBar 的四个 ambient |
| 页面推入退出 | `Theme.pageTransition` | RootView×2、PanelController Esc/⌘, 的 withAnimation×3、SettingsView 返回按钮 / 快捷键入口、ShortcutsView 返回、PreviewSupport corners |
| `Theme.snappy(Theme.durationTone)` | `Theme.selectionSlide` | Components ToneSelector |

注意事项：
- `withAnimation(旧) { … }` 与 `.animation(旧, value:)` 的替换是一一对应的，不要顺手改结构。
- TranslatorView 根部的四条 ambient `.animation(…, value:)` 挂在整棵 VStack 上，属于大范围隐式动画。本次先原样迁移曲线，**不要**趁机重构作用域（风险大收益小）；但在代码注释里标注"作用域偏大，值得未来收窄"。

### 2.3 特例处理

- **StreamingPlaceholder 脉冲**（`easeInOut 0.8 repeatForever`）：装饰性循环，保留 easeInOut。但要补 Reduce Motion：为真时不启动 `pulsing`，静置在 0.6 opacity。这是当前唯一合法的 `easeInOut` 与 `repeatForever`，在 CI grep 里豁免该文件段。
- **面板出现淡入**（PanelController `panel.animator().alphaValue = 1`，隐式 0.2s）：保留；Reduce Motion 为真时直接 `alphaValue = 1` 不走 animator。隐藏保持瞬时（orderOut），不对称是对的——召唤可以有仪式感，退场必须干脆。
- **`panel.animationBehavior = .utilityWindow`**：系统自带的出现缩放，保留不动。

---

## 第三部分：折叠/展开与页面切换的专项重设计

### 3.1 折叠展开（用户直接抱怨的点，最高优先级）—— 已解决，结论已定，别再改

现状（SettingsView `advancedSection` / `extraInstructionSection`，v1.11.0 之前）：chevron 带弹跳旋转 + 内容 `.transition(.identity)` 瞬间闪现 + 窗口另一条曲线追高。

**这一节最初设计的"内容和窗口用同一条时间线（`.transition(.opacity)` + `Theme.layoutChange`）"方案，以及它的回退方案（内容改用更快的 `Theme.stateChange`），都已经实际做过并被真实反馈否决——不是没验证，是验证完发现两版都不对，别再往这个方向试第三次。**

根因：只要 fold 的内容本身在做任何动画（哪怕只是透明度），SwiftUI 就会在动画期间持续向 `RootView` 的 `GeometryReader`/`PreferenceKey` 上报变化中的高度，而 `PanelController.setContentHeight` 每收到一次新高度就会用 `NSAnimationContext` 重新指向一次窗口的目标 frame。窗口因此在整个动画期间被连续"重新瞄准"，即使两条曲线各自都不带回弹，叠加出来的观感仍然是"页面先动一下、内容再弹开、然后才到位"的三段式动作，而不是一个干净的动作。两个方案（同曲线同时长 / 内容更快+窗口更慢）都摆脱不了这个机制性问题，因为问题根源是"内容动画"本身的存在，不是曲线或时长的选择。

**最终方案：只让窗口 resize 动，内容不参与动画。**

1. chevron：`Theme.stateChange`（0.18 纯减速），旋转 0→90°。这是唯一还在用 SwiftUI animation 的部分，它只影响自己的 `rotationEffect`，不影响布局，不会触发高度上报。
2. 内容：`.transition(.identity)`——点击的瞬间内容就以完整状态出现（不淡入、不缩放），高度在同一帧到达最终值，`onHeightChange` 只会收到一次目标高度，不会有中间值可追。
3. 窗口：`PanelController.setContentHeight` 仍然用 `NSAnimationContext` + `Theme.layoutChangeDuration`/`caTimingFunction`（M1 已经把这条曲线从弹簧换成纯减速——这才是真正解决"弹跳"的地方）。窗口一次性平滑长高到目标值，中途没有任何东西在改它的目标。
4. 效果：chevron 转 + 窗口长高，两个独立、互不干扰的动作同时发生，没有"抢跑—追赶"的相位差，也就没有三段式的观感。这跟这两个折叠区域改动之前的原始实现结构完全一样（原始代码本来就是"只有 chevron 动、内容瞬间弹出、窗口是唯一的运动"），唯一变化是窗口那条曲线从弹簧换成了减速曲线——这恰好也是用户最初反馈"弹跳"的真正原因，不需要额外的同步机制来解决。

### 3.2 页面推入（翻译页 ↔ 设置页 ↔ 快捷键页）

现状 RootView 用 `.move(edge:) + .opacity` 不对称转场配 snappy——方向语义是对的（设置从右进、翻译从左回），保留结构，仅做两件事：
1. 曲线换 `Theme.pageTransition`。
2. 现在 removal 和 insertion 都是全宽 move，两页交叠时总位移过大，中段会出现"两页都在飞"的拥挤感。把**退场页**的 move 幅度减半：`removal: .offset(x: ∓panelWidth * 0.5).combined(with: .opacity)`（iOS 导航栏的经典视差手法，退场页走一半距离先淡掉，进场页走全程）。panelWidth 从 panelState 取。改完明暗+SLOWMO 各验一次。

### 3.3 Toast

现状不统一：fellBack/truncatedInput 在底部（`padding(.bottom, 48)`）盖着译文，raceWon 在顶部。方案：
1. **全部收敛到顶部**，`padding(.top, 10)`，理由与 raceWon 当时挪上去相同——底部永远压着用户正要读的结果，顶部盖的是他已经写完的输入。
2. 转场统一为 `.move(edge: .top).combined(with: .opacity)`（从面板顶边滑下），动画 `Theme.stateChange`。删掉现有 `.scale(0.85)` 缩放——缩放+弹簧是"气泡弹出"隐喻，通知条应该是"滑入"隐喻。
3. 三个 toast 共用一个顶部 overlay 分支，删掉现在按 case 分裂的两个 overlay。

---

## 第四部分：UI 设计合理性与美观度评估

按影响排序。第 1 条是此前 OPTIMIZATION_GUIDE 批次4 里明确搁置的项（当时缺明暗截图验收条件，现在验收流程已跑通，应当补上）。

### 4.1 填充不透明度收敛为语义 token（最高优先级）

现状 `Color.primary.opacity(…)` 共 17 档散布各处，其中 0.05 / 0.055 / 0.06 / 0.065 / 0.07 这五档几乎肉眼不可分，是不同时间手调出来的。新增：

```swift
// Theme.swift
static let fillQuiet = Color.primary.opacity(0.05)      // 静态填充：字段底、badge、未选中胶囊（合并 0.05/0.055/0.06）
static let fillHover = Color.primary.opacity(0.07)      // 悬停态（合并 0.065/0.07）
static let fillActive = Color.primary.opacity(0.1)      // 按下/激活态（合并 0.08/0.09）
static let strokeHairline = Color.primary.opacity(0.08) // 描边、分隔线（合并 0.07 描边/0.08）
static let fillSelection = Color.primary.opacity(0.14)  // ToneSelector 旧系统药丸（0.12/0.14 合并）
```

替换范围：Components / SettingsView / TranslatorView 全部 `Color.primary.opacity(0.0xx)` 调用点。0.18（阴影）、0.35（占位圆点）、≥0.6（前景）不属于填充系统，不动。
**验收：明暗各截一套 `TUSI_PREVIEW=main/settings/picker`，逐控件比对合并前后无肉眼可见劣化——深色模式下 opacity 不是线性感知，这步不许跳过。**

### 4.2 圆角刻度收敛

现状 6 / 8 / 9 / 10 / 20 五档，其中 8/9/10 三档差 1pt 肉眼不可分，是伪刻度。收敛为三档：`radiusSmall = 6`（badge、小药丸）、`radiusStandard = 8`（字段、按钮、卡片、历史行、错误框、toast——合并原 8/9/10）、`panelCornerRadius = 20` 不变。删除 `radiusLarge` / `radiusToast`。

### 4.3 字号刻度收敛

现状 9 / 9.5 / 10 / 10.5 / 11 / 11.5 / 12 / 12.5 / 14 / 15 / 18 共 11 个字号、19 个 token。9.5/10.5/11.5 三个半级是刻度纪律崩坏的信号。收敛为 8 级整数刻度：**9 / 10 / 11 / 12 / 13 / 14 / 15 / 18**。映射：9.5→9（历史计数 badge）、10.5→10（caption2Medium/Bold、toneLabel）、11.5→12（footnote2 系、shortcutCombo）、12.5→13（body、bodyMonospaced）。
注意：**改字号必影响 CJK 测高**。TranslatorView 的行高全部走 AppKit 实测所以自动正确，但 `measureLineMetrics` 相关测试断言的常数若有硬编码需同步；改完跑 `swift test` + 明暗截图，重点看输入框 6 行、结果 14 行的裁切边界。此项收益是长期一致性，风险中等——**放最后一批做，单独成 commit，方便整体回退**。

### 4.4 选中态视觉语言统一

现状三种"选中"表达并存：slot tab / LanguagePill 用 accent 实心胶囊 + 白字；ToneSelector 用玻璃/灰药丸滑块；DirectionChip 激活只变 accent 文字色。这个分化**基本合理**（tab/pill 是"改变后续行为的选择"应该重，tone 是常驻三段器应该轻，chip 是状态指示器），不强行统一，但有一处要修：**LanguagePill 选中态没有悬停反馈，未选中态也没有**——同一行里 ToneSelector 有 hover、DirectionChip 有 hover，唯独语言药丸是死的。给 LanguagePill 补 hover：未选中 `fillQuiet→fillHover`，选中态 accent 亮度 +0.06（复用 CopyButton 的 `.brightness` 手法）。

### 4.5 设置页信息架构微调

1. **竞速子开关缩进**：「完成后提示谁更快」目前与父开关左对齐，读不出从属关系。子行 `padding(.leading, 12)`。
2. **分区分隔**：设置页现在只有一条 SoftDivider（testRow 之后）。整页实际有四个语义区：档位配置 / 附加要求 / 快捷键 / 行为开关。在「附加要求」之后、「快捷键」之前补一条 SoftDivider，四区节奏完整。
3. **race 开关的 caption 字色**：现在 `.secondary`，比其他行的辅助文案（`.tertiary`）重一级。统一为 `.tertiary`——警示信息靠文案说"请留意计费"就够了，不需要靠字色加重。

### 4.6 不动的东西（明确列出防止执行时手痒）

- 系统 accent color 策略（不引入自有品牌色）——正确，保持。
- 底栏布局、DirectionChip + 内联语言行交互——刚定稿，不动。
- 三 tab 等宽 + 短域名——刚定稿，不动。
- SoftDivider 渐变发丝线、面板 20pt 圆角、`.regularMaterial` toast 底——质感正确，保持。

---

## 实施顺序与验收

依赖关系：M1 是一切的地基，必须最先；U3 风险最高放最后。

| 批次 | 内容 | 验收 |
|---|---|---|
| M1 | Theme 动机 token 系统 + 64 处调用点机械迁移 + CI grep 门禁 + 骨架屏 Reduce Motion | `swift test` 全绿；`TUSI_SLOWMO=1` 现在能放慢**所有**动画；系统开启减弱动态后所有动画瞬时完成；grep 确认 UI 目录零裸曲线 |
| M2 | 折叠/展开单时间线（3.1）+ 页面推入视差（3.2）+ 面板淡入 RM | SLOWMO 逐帧看折叠：chevron/内容/窗口一条曲线；明暗截图 |
| M3 | Toast 统一顶部滑入（3.3） | `TUSI_PREVIEW=racewon` + 手动触发 fallback 场景截图 |
| U1 | 填充 token 收敛（4.1）+ 圆角收敛（4.2） | 明暗两套 main/settings/picker 截图逐控件比对 |
| U2 | 选中态 hover 补齐（4.4）+ 设置页微调（4.5） | 明暗截图 |
| U3 | 字号刻度收敛（4.3），单独 commit | `swift test` + 明暗截图重点看 CJK 裁切边界 |

每批独立 commit、可独立回退；M 系列做完跑一次 `./build.sh release` 门禁，U 系列做完再跑一次。全部完成后 CHANGELOG 记一条（版本号由用户决定，不要自行发版）。
