# Tusi 动画系统 v2 重构方案

> **状态：已实施（v1.11.8）。** 本文保留为实施记录。
>
> ⚠️ **动手前先读 §0。** 本方案原始版本的诊断里有两条是错的——它们来自读代码的推理，实机测量后不成立。§0 记录了测出来的事实、被推翻的结论，以及最终采用的架构与原方案的差别。§2 的缺陷编号保留原样，但每条都标了「成立 / 被推翻」。
>
> 前一版方案见 [MOTION_UI_REDESIGN_PLAN.md](MOTION_UI_REDESIGN_PLAN.md)（v1.11.1，已落地）。

---

## 0. 实机测量推翻了什么（最重要的一节）

方法：给 `PanelController.setContentHeight` 和预览脚本各加一行带时间戳的日志，用 `TUSI_PREVIEW=push TUSI_SLOWMO=1` 把每个动作放慢 10 倍，再用 Quartz 的 `CGWindowListCopyWindowInfo` 以 ~80Hz 采样窗口真实高度。这是本次唯一可信的证据来源；此前的诊断全部来自读代码。

### 测出来的第一条事实：SwiftUI 根本不输出中间高度

`GeometryReader` + `onPreferenceChange` 在一次转场里**只触发一次，带的是最终值**，时间点大约在动作开始后 25–80ms（一两个布局 pass）。不是每帧，不是插值。

这一条直接推翻了原方案的核心论断：

- **缺陷 B「内容高度被缓动两次」——不成立。** 窗口侧从来没有拿到过中间值，也就无从「二次缓动」。原方案据此提出的「窗口降级为哑镜子、删掉全部 `NSAnimationContext`」如果照做，结果是**所有高度变化直接瞬移**——实测确认过：折叠、历史、翻页全部变成硬切。这个改动做出来后被测量当场否掉，已回滚。
- 顺带解释了 `followsAnimatedHistoryHeight` 那个特例分支到底在做什么：它不是在「避免二次缓动」，而是**彻底关掉了历史开合时窗口的动画**。所以此前历史展开的真实观感是「内容用 0.26s 淡入长高，窗口瞬间跳到位」。这是一个真实缺陷，只是原因和当初注释里写的不一样。

### 测出来的第二条事实：翻页返回没有两段式

- **缺陷 A「设置页返回时高度先卡住、页面滑完才收缩」——不成立。** 实测：无论去还是回，新高度都在动作后 **35ms** 内就到达 `PanelController`。SwiftUI 在转场一开始就把离场页从布局里移除了，只保留它的绘制；`ZStack` 的 `max()` 并不会把高度按住。
- 为此写的「按页测量高度 + 用当前页高度约束 ZStack」那套（`PageHeightsKey` / `measuredPage`）因此没有任何收益，反而引入了一个**真实回归**：它和翻译页重新挂载后的自量测竞争，会把面板锁在比正确值矮 21pt 的高度上，正好吃掉结果区的最后一行。已全部删除。

### 最终采用的架构（与原方案的差别）

原方案：SwiftUI 独占时间线，窗口逐帧镜像，`NSAnimationContext` 清零。
**实际采用：窗口必须自己跑动画（因为它只拿得到终点值），所以让它和视图层跑的是同一条动画。**

> **所有会改变面板高度的动作共用同一个时长。**
> `Theme.windowResizeDuration` = 0.22s = `.layout` 的时长 = `.page` 的时长，曲线同为 `Theme` 的那一条。窗口和内容同起、同形、同止，唯一的差别是窗口晚出发约 25–80ms（一次布局 pass，无法消除）。
> 推论，也是新增的硬性规则：**任何会改变面板高度的动画只能用 `.layout` 或 `.page`，不能用 `.state`。** 这条比原方案的「一次操作一个 token」更强，因为它可以被逐点审计。

`.page` 因此从 0.28s 降到 0.22s——原来它比窗口长 60ms，这才是翻页时窗口和页面「不是一个节奏」的真正原因。

### 验收数据（`TUSI_SLOWMO=1`，故每段应 ≈2.2s）

改造前：每个动作 = 1 次高度跳变，窗口无插值。
改造后：

```
  语言选择行展开   159 → 187   一段  2.1s
  语言选择行收起   187 → 158   一段  1.7s
  历史展开         159 → 241   一段  2.0s
  历史收起         240 → 158   一段  1.9s
  翻译页 → 设置页  160 → 644   一段  2.1s
  设置页 → 翻译页  643 → 158   一段  2.1s   ← 回到 158，不是 137
  翻译页 → 设置页  161 → 644   一段  2.1s
  设置页 → 翻译页  643 → 158   一段  2.2s
```

每个动作一段连续曲线，无二段、无中途停顿、无末尾补跳。

---

## 1. 结论先说（已按实测修正）

问题不在参数，在**同一个动作被拆成好几条时长不同的时间线**，以及**token 在调用点按「哪个属性在变」随手挑，而不是按「用户做了什么」**。

v1.11.1 建立的东西是对的，留着：一条统一曲线 `(0.25, 0.1, 0.25, 1.0)`、语义 token、Reduce Motion 单点检查。

真正坏掉的：

1. **窗口和内容的时长对不上。** 翻页时 SwiftUI 走 0.28s，窗口走 0.22s；历史开合时窗口动画被一条特例分支整个关掉（内容淡入长高 0.26s，窗口瞬移）。
2. **折叠展开是三个节奏拼的**：chevron 0.18s、内容 0s（`.transition(.identity)`）、窗口 0.22s。
3. **「一次操作 = 一个 token」只写在文档里，没写进代码里。**

解法：**所有会改变面板高度的动作共用一个时长**（`Theme.windowResizeDuration` = 0.22s），窗口和视图层因此跑的是同一条动画；token 按起因选，全部声明式；再用一条源码扫描测试把规则钉住。

（原方案在这里主张「窗口降级为逐帧镜像、删掉全部 AppKit 动画」。那是错的，理由见 §0。）

## 2. 现状诊断

### 缺陷 A：翻页时面板高度走两段 —— ❌ **被实机推翻，见 §0**

> 下面这段推理读起来成立，实测不成立：SwiftUI 转场一开始就把离场页移出布局，`max()` 按不住高度。保留原文是为了记住「只读代码就下结论」会错在哪里。

[RootView.swift:33-55](Sources/Tusi/UI/RootView.swift:33) 是一个 `ZStack`，翻页期间新旧两页**同时挂载**。`.move` / `.offset` 转场只改变绘制位置，不改变布局尺寸，所以 ZStack 的高度在整个转场期间等于两页的 `max`。而 [PanelHeightKey](Sources/Tusi/UI/RootView.swift:3) 的 `reduce` 正是 `max`。

于是：

- **翻译页 → 设置页**（设置页更高）：t=0 两页都挂载 → 高度立刻跳到设置页的高度 → 窗口用 0.22s 长高；页面用 0.28s 滑入。**窗口比内容早 60ms 停住。**
- **设置页 → 翻译页**：t=0 高度仍是 `max` = 设置页高度，全程不变；t=0.28 设置页卸载 → 高度才掉到翻译页高度 → 窗口这时**才开始**用 0.22s 收缩。总时长 0.5s，观感是「页面先滑完，面板再单独缩一下」。

这一条是纯代码推导，不需要实机确认。返回方向的两段式几乎肯定就是「感觉不合理」的主要来源之一。

### 缺陷 B：内容高度被缓动两次 —— ❌ **被实机推翻，见 §0**

> 前提就不成立：SwiftUI 从不把中间高度交给 `onPreferenceChange`，窗口拿到的一直只有终点值。真正的缺陷是另一个——历史开合时窗口动画被那条特例分支整个关掉了。

`setContentHeight` 只在三种情况下**不**做 AppKit 动画（[PanelController.swift:290](Sources/Tusi/PanelController.swift:290)）：streaming 中、Reduce Motion、以及 history 折叠期间那个特例窗口。

但 SwiftUI 侧**连续吐出中间高度**的地方不止 history 一个：

- [TranslatorView.swift:424](Sources/Tusi/UI/TranslatorView.swift:424) `visibleSectionHeight` 是个被 `.animation(Theme.layoutChange, value: engine.hasResultSection)` 驱动的 `.frame(height:)`——结果区出现/消失时它逐帧变化。
- 设置页任何被 `withAnimation` 包住、且高度会变的状态切换（`editingIndex`、`useLocalModel`、`raceFastestEnabled`…）。

这些中间值每一帧都会触发一次全新的 `NSAnimationContext` 0.22s 缓动。**对一个已经在缓动的目标再缓动一次**，数学上是一阶滞后追踪：窗口永远落后内容一截，末尾拖出一条软尾巴。history 当年遇到的「expand/collapse jitter + 最后一跳」就是这个，只是当时按单点修了。

### 缺陷 C：折叠展开是三个节奏拼出来的 —— ✅ **成立，已修**

设置页的「高级选项」/「附加要求」（[SettingsView.swift:587](Sources/Tusi/UI/SettingsView.swift:587) / [:669](Sources/Tusi/UI/SettingsView.swift:669)）：

| 部件 | 时长 | 曲线 |
|---|---|---|
| chevron 旋转 | 0.18 (`stateChange`) | SwiftUI |
| 字段出现 | 0 (`.transition(.identity)`) | 无 |
| 窗口长高 | 0.22 (`layoutChangeDuration`) | AppKit |

代码注释里明确写着「试过让字段跟随，两种写法都产生三段式，放弃了，让字段瞬间弹出」。**那个放弃是缺陷 B 逼出来的**——因为窗口在做二次缓动，任何会动的内容都让它追不上。修掉 B 之后这个妥协就不必要了，字段可以正常地跟着长出来。

### 缺陷 D：token 按「属性」挑，不按「起因」挑 —— ✅ **成立，已修**

同一个用户动作触发多个 token 的实例：

| 用户动作 | 涉及的 token | 位置 |
|---|---|---|
| 点 DirectionChip 展开语言选择 | `stateChange` 0.18（`withAnimation`）+ `layoutChange` 0.22（`.animation(value:)`）+ 窗口 0.22 | [TranslatorView.swift:634](Sources/Tusi/UI/TranslatorView.swift:634)、[:230](Sources/Tusi/UI/TranslatorView.swift:230)、[:559](Sources/Tusi/UI/TranslatorView.swift:559) |
| 展开设置里的折叠区 | 0.18 + 0 + 0.22 | 见缺陷 C |
| 翻译完成（出现复制按钮） | `layoutChange` 0.22（底栏）+ `layoutChange` 0.22（结果区）+ `pageTransition` 无关 + 窗口 0.22 | [TranslatorView.swift:729-731](Sources/Tusi/UI/TranslatorView.swift:729) |
| 翻页 | `pageTransition` 0.28 + 窗口 0.22 | 缺陷 A |

注意语言选择那条：`withAnimation(Theme.stateChange)` 会覆盖 `.animation(Theme.layoutChange, value:)`，所以**实际跑的是 0.18，而代码里写着 0.22 的那行是死的**。读代码的人会被骗。

### 缺陷 E：三种 hover 写法并存 —— ✅ **成立，已修**

- `withAnimation(Theme.microMotion) { hovering = inside }`（[Components.swift:170](Sources/Tusi/UI/Components.swift:170)、[:217](Sources/Tusi/UI/Components.swift:217)）
- `.onHover { hovering = $0 }` + `.animation(Theme.microMotion, value: hovering)`（[Components.swift:315](Sources/Tusi/UI/Components.swift:315)、[TranslatorView.swift:788](Sources/Tusi/UI/TranslatorView.swift:788)）
- `.onHover { shortcutsRowHovering = $0 }` + 父级 `.animation`（[SettingsView.swift:548](Sources/Tusi/UI/SettingsView.swift:548)）

第一种有真实副作用：`withAnimation` 是**事务级**的，同一个 runloop 里恰好一起变的任何无关状态都会被这条 0.12s 曲线捎带上。鼠标滑过恰好撞上翻译返回，就会看到不该动的东西动了一下。这是「偶尔莫名其妙抖一下」的合理嫌疑人。

### 缺陷 F：几个转场词汇跟全局对不上 —— ✅ **成立，已修**

- [SettingsView.swift:128](Sources/Tusi/UI/SettingsView.swift:128)：钥匙串保存的绿勾用 `.scale(scale: 0.7)`，驱动它的是 `microMotion` **0.12s**。120ms 内缩放 30% —— 那不是「出现」，那是闪一下。
- [TranslatorView.swift:726](Sources/Tusi/UI/TranslatorView.swift:726)：复制按钮 `.scale(scale: 0.9)` 弹出，而同一行里的停止/翻译按钮全是纯 `.opacity`。一行控件三种出场方式。
- [Components.swift:312](Sources/Tusi/UI/Components.swift:312)：CopyButton hover 时 `scaleEffect(1.03)`——全应用唯一一个会因悬停而变大的控件。
- 骨架屏 → 结果文字（[TranslatorView.swift:335](Sources/Tusi/UI/TranslatorView.swift:335) 的 `switch engine.state`）**没有任何转场**，脉冲条被文字瞬间顶替，同时外框在缓动高度。

### 缺陷 G：面板召唤动画不在系统里 —— ✅ **成立，已修**

[PanelController.swift:180](Sources/Tusi/PanelController.swift:180) 的 `panel.animator().alphaValue = 1` 没有包在 `NSAnimationContext` 里，吃的是 AppKit 默认 **0.25s**，曲线也不是 `Theme.caTimingFunction`。这是全应用被看到次数最多的一次动画（⌥Space 每天几十上百次），却是唯一一个绕过 token 系统的。0.25s 对一个「唤起即用」的面板明显偏长。

同时 `hide()` 完全没有动画（瞬间 `orderOut`）。出入不对称本身可以是对的（消失要快），但现在它是没写下来的巧合，不是决定。

### 缺陷 H：Reduce Motion 不会实时生效 —— ✅ **成立，已修**

`Theme.motion()` 每次都同步读 `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`（[Theme.swift:181](Sources/Tusi/UI/Theme.swift:181)），但这个读取**不建立 SwiftUI 依赖**。用户在系统设置里打开「减弱动态效果」，Tusi 已经渲染出来的视图不会重算，要等下次 body 求值才碰巧生效。

---

## 3. 新原则（四条）

1. **一次操作 = 一条时间线 = 一个 token。** token 由「用户做了什么」决定，不由「哪个属性在变」决定。
2. **凡是会改变面板高度的动画，只能用 `.layout` 或 `.page`。** 这两个 token 与 `Theme.windowResizeDuration` 同长，窗口才追得上。`.state` 只留给确定不影响高度的东西（悬停底色、行内图标替换、胶囊填充）。
3. **全部声明式，全应用零 `withAnimation`。** 命令式事务会把同一 runloop 里恰好一起变的无关状态一并带上；绑到「值」上，起因才明确、影响面才局部。这也是 Reduce Motion 能走 `@Environment` 的前提。
4. **面板 chrome 只减速，不回弹。** 唯一的弹簧是 ToneSelector 的滑动药丸。

## 4. 架构改动（已实施）

### 4.1 `Theme` 收敛为一个 `Motion` 枚举 + 一个 View 扩展

`Theme.Motion`：`.micro` 0.12 / `.state` 0.18 / `.layout` 0.22 / `.page` 0.22 / `.selection`（唯一弹簧）。
唯一入口是 `.motion(_:value:)`，内部 `MotionModifier` 从 `@Environment(\.accessibilityReduceMotion)` 读 Reduce Motion——环境值会建立 SwiftUI 依赖，系统设置一改立刻重算，直接读 `NSWorkspace` 做不到。

删除：`Theme.snappy` 遗留物、`historyTransition`（0.26，它存在只是为了掩盖历史那条特例分支造成的窗口瞬移）、`layoutChangeDuration`、`historyTransitionDuration`。
新增：`windowResizeDuration`（0.22，`.layout`/`.page` 与窗口共用）、`panelAppearDuration`（0.14）。

### 4.2 `PanelController` 只剩两处 AppKit 动画

`setContentHeight` 用 `windowResizeDuration` + `caTimingFunction` 缓动，**只在两种情况下不动画**：

- 流式输出中（逐行到达，每行一次 0.22s 动画会叠出几十个重叠 resize 并把文字拖在光标后面；视图层同样不动画，两边一致）；
- Reduce Motion。

删除：`shouldAnimateHeightChange`、`followsAnimatedHistoryHeight`、`historyResizeTask`、`beginFollowingAnimatedHistoryHeight()`、`panelState.$showHistory` 的 sink、`+0.05` 经验补偿值、连同不再需要的 `Combine` 依赖。三个特例分支变成一个。

召唤淡入改用 `panelAppearDuration` 0.14s + 同一条曲线（原先是 AppKit 默认的 0.25s）。`hide()` 保持瞬间，并在代码里写下理由：**召唤要快，消失要立刻。**

### 4.3 `Disclosure`：折叠展开的唯一实现

内容常驻布局并按自然尺寸测量，**动画的是容器自己的高度**，内容在容器内裁切淡入。这样高度是连续变化的，也就有东西可以让窗口对齐；`if expanded { … }` 只能让 stack 高度一步跳变。

`.fixedSize(horizontal: false, vertical: true)` 是关键：它让内容在外层 frame 提议 0 高度时仍报告理想高度，否则测量会随折叠一起塌掉、再也展不开。折叠态还要 `.disabled` + `.accessibilityHidden`，否则 Tab 会落进看不见的输入框。

替换了四处各写一遍的写法：设置页两个折叠区（连同它们的 `.transition(.identity)`）、语言选择行（连同它多余的 `.move(edge: .bottom)`）。

### 4.4 `RootView`：一个 `Page` 值驱动整个翻页

`activePage` 取代两个 `.animation(value:)`（`showSettings` / `showShortcuts`），一个 `.motion(.page, value: activePage)` 同时驱动滑动、高度和两页内部所有淡入淡出。

**没有**按页约束高度——那套试过并已删除，理由见 §0。

## 5. 转场词汇表（已实施，唯一合法用法）

| 元素类别 | 转场 | token |
|---|---|---|
| 页 ↔ 页 | 水平推入（入全程 / 出半程 + 淡出，`retreat()` 保留） | `.page` 0.22 |
| 折叠区 / 语言选择行 | `Disclosure`（容器高度 + 淡入，裁切，**不 move**） | `.layout` |
| 结果区 / 历史 | 顶部对齐、只动视口高度 + 交叉淡入 | `.layout` |
| 骨架屏 ↔ 结果文字 ↔ 错误框 | `.opacity` 交叉淡入，由一个 `ResultPhase` 值驱动 | `.layout` |
| 输入框下的提示（截断 / 剩余字数） | `.opacity`，由一个 `InputNotice` 值驱动 | `.layout` |
| 增删整行的提示（谁快用谁子项、更新状态、连接结果、快捷键错误与确认） | `.opacity` | `.layout` |
| Toast | 从顶部 move + 淡入 | `.layout` |
| 底栏控件互换（翻译 / 停止 / 复制 / 本地模型图标） | `.opacity`，**无 scale**，由一个 `BarConfiguration` 值驱动 | `.layout` |
| 确认态图标（复制 ✓） | `.contentTransition(.symbolEffect(.replace))` | `.state` |
| 钥匙串 ✓、方向 chip 文案、语言胶囊选中态 | `.opacity` / 填充色，行高不变 | `.state` |
| hover / 按压 | 底色、亮度 | `.micro` |
| 选中药丸滑动 | `matchedGeometryEffect` | `.selection`（唯一弹簧） |
| 骨架脉冲 | `easeInOut(0.8).repeatForever` | 装饰性例外（`motion-exception:`） |

注意 `.layout` 的覆盖面比原方案预想的大得多——**凡是增删一行、改变面板高度的，一律 `.layout`**，哪怕它自己看起来只是个淡入。这是 §3 规则 2 的直接后果，也是逐点审计时最容易漏的一类（原方案曾把「谁快用谁」的子开关、更新状态行、快捷键错误行都放在 `.state`，它们全都会改变高度）。

被删掉的：`.scale(scale: 0.9)`（复制按钮弹出）、`.scale(scale: 0.7)`（钥匙串 ✓，且驱动它的是 0.12s——120ms 内缩放 30% 不是出现，是闪一下）、`scaleEffect(1.03)`（复制按钮悬停放大，全应用唯一会因悬停变大的控件）、四处 `.transition(.identity)`、`historyTransition` token。

`.state` 与 `.layout` 的分界线不是「哪个属性在变」，而是**这次变化会不会让面板变高变矮**。会，就必须和窗口同长。

---

## 6. 实施与验收（已完成）

门禁：`swift test` 158 项全绿；`./build.sh release` 通过（`-strict-concurrency=complete -warnings-as-errors`，双架构）。

**M0 · 防回归测试**（`Tests/TusiTests/MotionConventionTests.swift`）——扫描 `Sources/Tusi/**`，逐条断言并给出 `文件:行号`：

- 全应用不出现 `withAnimation`；
- `Theme.swift` 之外不出现裸 `.animation(`；
- `Theme.swift` 之外不出现裸曲线（`.snappy` / `.easeOut` / `.easeInOut` / `.spring(` / `.timingCurve(` / `.linear(duration:` …）；
- 不出现 `NSAnimationContext`；
- 不出现 `.transition(.identity)`；
- 视图不直接读 `NSWorkspace...ReduceMotion`（`PanelController` 除外，它没有环境可读）。

唯一逃生口是在行内或上一行写 `// motion-exception:` 并说明理由，且**逃生口的总数被断言钉死为 3**（骨架脉冲循环、窗口 alpha、窗口 frame），加一个就得在同一次提交里解释。

这条测试做过反向验证：故意注入一个 `.animation(.snappy(duration: 0.3), value:)` 和一个 `.transition(.identity)`，三条规则同时报错并指出确切行号。

**M1–M4 · 代码改造**——见 §4、§5。

**M5 · 验收**——`TUSI_SLOWMO=1` + 窗口高度采样（数据见 §0），明暗两套外观各截图肉眼确认：设置页折叠区展开态、语言选择行展开态、翻译页往返后布局无回归。

新增预览场景 `TUSI_PREVIEW=push`：按脚本依次触发语言选择行、历史、两轮翻页往返，配合 `TUSI_SLOWMO=1` 就能不用手动操作地复现整套动效供测量。

---

## 7. 尚未验证的一项

**Reduce Motion 的实时切换没有实测。** 代码路径已从 `NSWorkspace` 直读改成 `@Environment(\.accessibilityReduceMotion)`，编译与构建通过，但验证它需要在系统设置里真开一次「减弱动态效果」——那属于改用户的系统设置，没有代做。要确认的话：开着面板去「系统设置 ▸ 辅助功能 ▸ 显示 ▸ 减弱动态效果」拨一下，面板应当立刻停止动画（尤其是等待时的骨架脉冲），不需要重启 Tusi。

---

## 8. 明确不做的事

- **不恢复逐字流式显示。** 结果一次性原子提交的契约不动。
- **不给面板加入场缩放以外的任何「特效」**（模糊、位移、弹跳）。这是效率工具，不是展示型 app。
- **不做逐元素 stagger 入场。** 面板内容不到二十个元素，错峰只会让每次操作都变慢。
- **不为 macOS 26 的 Liquid Glass 单开一套动效。** 材质是材质，动效是动效；ToneSelector 现有的分支已经够了。
- **不动窗口宽度动画。** `setContentMinWidth` 是瞬时的，宽度变化只在语言切换/首次布局时发生，罕见且不该被注意到——保持瞬时是对的。

---

## 9. 净效果（实测/实数）

| | 之前 | 之后 |
|---|---|---|
| 会改变高度的动作的时长 | 0.18 / 0.22 / 0.26 / 0.28 四种，窗口固定 0.22 | 统一 0.22，窗口同长同曲线 |
| 翻页时窗口与页面 | 差 60ms（0.22 vs 0.28） | 同长；窗口晚出发 ~35–80ms（一次布局 pass，无法消除） |
| 历史开合时的窗口 | 完全不动画（特例分支关掉了），内容却在动 | 与内容同长同曲线 |
| 折叠展开可见相位 | 3 个（chevron 0.18 / 内容 0 / 窗口 0.22） | 1 个 |
| `PanelController` 里的高度分支 | 3 个特例 + 1 个 Task 定时器 + `+0.05` 补偿 | 1 个判断（流式 / Reduce Motion） |
| 动机 token | 6 个 + 2 个时长常量 | 5 个 + 2 个（窗口 resize、召唤） |
| `withAnimation` 调用点 | 17 处 | 0 |
| hover 写法种数 | 3 | 1 |
| 召唤淡入 | AppKit 默认 0.25s，不走 token | 0.14s，走 token 曲线 |
| Reduce Motion | 改设置后不实时生效 | 走 `@Environment`，实时（未实测，见 §7） |
| 防回归 | 文档约定 | 6 条源码扫描断言 + 逃生口计数 |
