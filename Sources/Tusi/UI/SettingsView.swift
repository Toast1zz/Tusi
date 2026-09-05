import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var engine: TranslationEngine
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var panelState: PanelState
    @EnvironmentObject private var updateChecker: UpdateChecker

    @State private var showKey = false
    @State private var testStates: [Int: TestState] = [:]
    @State private var testTasks: [Int: Task<Void, Never>] = [:]
    @State private var testGenerations: [Int: Int] = [:]
    @State private var shortcutsRowHovering = false
    @State private var advancedExpandedOverride: [Int: Bool] = [:]
    @State private var extraInstructionExpandedOverride: Bool?

    private enum FocusedField: Hashable {
        case baseURL
        case model
        case providerOrder
        case apiKey
    }

    @FocusState private var focusedField: FocusedField?

    enum TestState: Equatable {
        case idle
        case testing
        case success(TranslationService.ConnectionTestResult)
        case failure(String)
    }

    private var testState: TestState { testStates[editingIndex] ?? .idle }

    // Lives in PanelState, not local @State: a trip to the Shortcuts secondary page
    // unmounts and remounts this view, which would otherwise reset the selected tab.
    private var editingIndex: Int {
        get { panelState.settingsProfileIndex }
        nonmutating set { panelState.settingsProfileIndex = newValue }
    }

    /// Indexing guard: `profiles` is a fixed three-slot invariant (primary, backup,
    /// local) maintained by the UI, but a stale `settingsProfileIndex` must degrade to
    /// slot 0 instead of crashing on an out-of-range subscript if it ever breaks.
    private var safeEditingIndex: Int {
        settings.profiles.indices.contains(editingIndex) ? editingIndex : 0
    }

    private var isEditingLocalSlot: Bool {
        editingIndex == SettingsStore.localProfileIndex
    }

    /// True when the profile being edited points at a local (loopback) server — used to
    /// hide the API Key field, since local inference servers don't take one.
    private var isCurrentProfileLocal: Bool {
        settings.profiles.indices.contains(editingIndex)
            && !settings.profiles[editingIndex].config.requiresAuth
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                header

            slotTabs

            VStack(alignment: .leading, spacing: 12) {
                labeledField("接口地址", focused: focusedField == .baseURL) {
                    TextField("https://api.example.com/v1", text: $settings.profiles[safeEditingIndex].baseURL)
                        .textFieldStyle(.plain)
                        .font(Theme.bodyMonospaced)
                        .focused($focusedField, equals: .baseURL)
                        .accessibilityLabel("接口地址")
                }
                labeledField("模型", focused: focusedField == .model) {
                    TextField("model-name", text: $settings.profiles[safeEditingIndex].model)
                        .textFieldStyle(.plain)
                        .font(Theme.bodyMonospaced)
                        .focused($focusedField, equals: .model)
                        .accessibilityLabel("模型")
                }
                advancedSection
                if isCurrentProfileLocal {
                    // Local (loopback) inference servers don't take an API key — Ollama,
                    // LM Studio, llama.cpp-server. Showing the field here would push users
                    // to type a fake key; a quiet hint is more honest.
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "desktopcomputer")
                            .font(Theme.caption2)
                            .padding(.top, 1)
                        Text("本地服务无需 API Key")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radiusStandard, style: .continuous)
                            .fill(Theme.fillQuiet)
                    )
                } else {
                    labeledField("API Key", focused: focusedField == .apiKey) {
                        HStack(spacing: 5) {
                            Image(systemName: "lock.fill")
                                .font(Theme.caption2)
                            Text("API Key 仅保存在本机钥匙串，只发送给你配置的 API 服务")
                        }
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                    } content: {
                        HStack(spacing: 6) {
                            Group {
                                if showKey {
                                    TextField("sk-…", text: $settings.profiles[safeEditingIndex].apiKey)
                                } else {
                                    SecureField("sk-…", text: $settings.profiles[safeEditingIndex].apiKey)
                                }
                            }
                            .textFieldStyle(.plain)
                            .font(Theme.bodyMonospaced)
                            .focused($focusedField, equals: .apiKey)

                            if settings.keychainSaved {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(Theme.footnote)
                                    .foregroundStyle(.green)
                                    .transition(.opacity)
                            }

                            Button {
                                showKey.toggle()
                            } label: {
                                Image(systemName: showKey ? "eye.slash" : "eye")
                                    .font(Theme.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help(showKey ? "隐藏" : "显示")
                            .accessibilityLabel(showKey ? "隐藏" : "显示")
                        }
                        // `.state`, not `.micro`: this is a confirmation appearing, not
                        // hover feedback. It used to scale up from 0.7 over 0.12s, which
                        // is not an element arriving — it is a flash.
                        .motion(.state, value: settings.keychainSaved)
                        .accessibilityLabel("API Key")
                    }
                }

                if let error = settings.keychainError {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(error)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // Only for failures a second attempt can actually clear (locked
                        // device, denied prompt). A corrupt item would fail identically,
                        // so offering retry there would just teach the button to lie.
                        if settings.keychainErrorIsRetryable {
                            Button("重试") { settings.retryLoadKeys() }
                                .buttonStyle(.plain)
                                .font(Theme.bodySmallSemibold)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .font(Theme.caption)
                    .foregroundStyle(.orange)
                }
            }

            testRow

            SoftDivider()

            routingSection

            SoftDivider()

            extraInstructionSection

            SoftDivider()

            shortcutsNavRow

            SoftDivider()

            VStack(alignment: .leading, spacing: 10) {
                settingToggle("保存翻译历史", isOn: $settings.saveHistoryEnabled)
                settingToggle("保留输入草稿", isOn: $settings.saveDraftEnabled)
                Text("关闭保存会删除对应的本机记录")
                    .font(Theme.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("清除输入草稿")) { engine.clearDraft() }
                    .buttonStyle(.plain)
                    .disabled(engine.input.isEmpty)
                if let error = engine.persistenceError {
                    Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(Theme.body)
            .toggleStyle(.switch)
            .controlSize(.mini)

            // Bounded on both sides. Without the second divider the rows below —
            // auto-copy, launch at login, updates — read as part of "翻译路线", which
            // is exactly the kind of false grouping this page is being cleaned up to
            // stop making.
            SoftDivider()

            // One VStack, one spacing value, for every row on the page from here down
            // (including the multi-line race unit below) — three separately-spaced
            // blocks used to rely on the outer page spacing (14) between them and an
            // inner spacing (10) within them, which read as uneven rhythm rather than
            // a deliberate grouping.
            VStack(alignment: .leading, spacing: 10) {
                settingToggle("翻译完成后自动复制", isOn: $settings.autoCopy)
                settingToggle("登录时启动", isOn: $settings.launchAtLogin)
                if let error = settings.launchAtLoginError {
                    Text(error)
                        .font(Theme.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                updateSettingRow
                // The sound preference reads as a distinct sense channel, not a
                // translation behavior, but shares the same row rhythm as everything
                // else here. Switching it off is deliberately silent (muting must not
                // announce itself); switching it on plays one quiet toggle-on cue.
                soundToggleRow

            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(Theme.body)

                if panelState.globalHotkeyFailed {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(Theme.caption2)
                        Text("全局呼出快捷键注册失败，可能被其他应用占用；换一个组合键，或点菜单栏图标呼出")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Theme.caption)
                    .foregroundStyle(.orange)
                }

            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height + 36)
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .onChange(of: settings.profiles) { _, _ in
            cancelTests()
            testStates.removeAll()
        }
        .onChange(of: editingIndex) { _, _ in
            showKey = false
            cancelTests()
        }
        // Leaving the page mid-recording would otherwise swallow the next keystroke
        // typed into the translator.
        .onDisappear {
            panelState.recordingShortcut = nil
            panelState.shortcutError = nil
            cancelTests()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                panelState.showSettings = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(Theme.bodySmallSemibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.fillQuiet))
            }
            .buttonStyle(.plain)
            .help(settings.commandLabel(L("返回"), action: .close))

            Text("设置")
                .font(Theme.title)

            Spacer()

            Text("Tusi v\(appVersion)")
                .font(Theme.caption)
                .foregroundStyle(.quaternary)
        }
    }

    /// Read from the bundle so it can never drift from the shipped version.
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    // MARK: - Slot tabs

    private var slotTabs: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(0...SettingsStore.localProfileIndex, id: \.self) { index in
                    slotTab(index)
                        .frame(maxWidth: .infinity)
                }
            }

            if isEditingLocalSlot {
                localSlotRoleRow
            } else {
                onlineSlotRoleRow
            }
        }
    }

    private func slotTab(_ index: Int) -> some View {
        let selected = editingIndex == index
        let isPrimary = settings.primaryIndex == index
        let isLocal = index == SettingsStore.localProfileIndex
        return Button {
            editingIndex = index
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(settings.profiles[index].isUsable
                          ? AnyShapeStyle(Theme.success)
                          : AnyShapeStyle(Color.secondary.opacity(0.35)))
                    .frame(width: 5, height: 5)
                Text(isLocal ? "本地模型" : (isPrimary ? "主用" : "备用"))
                    .font(Theme.footnote2Semibold)
                    .fixedSize()
                // No `.fixedSize()` here (unlike the role label): the three tabs now
                // share the row equally, so the host name is exactly the part that
                // should give way and truncate on a long one, not force the capsule
                // wider than its equal share.
                Text(settings.label(for: index))
                    .font(Theme.caption)
                    .opacity(0.7)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(
                    selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.fillQuiet)
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Slot roles

    /// The local slot's role line. Same "action, or current state plus the way out"
    /// pattern as the primary/backup line below — the local slot is an ordinary slot
    /// with an ordinary role now, not a standing mode that bypassed the rest of the app.
    @ViewBuilder
    private var localSlotRoleRow: some View {
        HStack(spacing: 6) {
            if !settings.localAvailable {
                Text("还需要填好下面的接口地址和模型")
                    .font(Theme.caption)
                    .foregroundStyle(.quaternary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if settings.routeStart == .local {
                Label("翻译从这里开始", systemImage: "checkmark.seal.fill")
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)

                if settings.onlineAvailable {
                    Text("·")
                        .font(Theme.caption)
                        .foregroundStyle(.quaternary)
                    Button {
                        settings.routeStart = .online
                    } label: {
                        Text("改为先用在线")
                            .font(Theme.caption2Medium)
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    settings.routeStart = .local
                } label: {
                    Label("设为起点", systemImage: "arrow.up.circle")
                        .font(Theme.caption2Medium)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)

                Text(settings.commandLabel(L("换在线重译"), action: .translate))
                    .font(Theme.caption)
                    .foregroundStyle(.quaternary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The primary/backup role line. Under 同时请求 there is no primary — both slots are
    /// asked at the same time — so the page says that instead of offering a choice that
    /// would change nothing.
    @ViewBuilder
    private var onlineSlotRoleRow: some View {
        HStack(spacing: 6) {
            if settings.onlineStrategy == .concurrent && settings.concurrentAvailable {
                Label("同时请求，两套地位相同", systemImage: "arrow.trianglehead.branch")
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
            } else if settings.primaryIndex == editingIndex {
                Label("当前为主用，优先使用这套", systemImage: "checkmark.seal.fill")
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Button {
                    settings.primaryIndex = editingIndex
                } label: {
                    Label("设为主用", systemImage: "arrow.up.circle")
                        .font(Theme.caption2Medium)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)

                Text(settings.profiles[editingIndex].isUsable
                     ? "· 现在是主用失败后的备用"
                     : "· 填好后可作为主用失败时的备用")
                    .font(Theme.caption)
                    .foregroundStyle(.quaternary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Routing

    /// The two questions that used to be four booleans.
    ///
    /// They were never independent: the race path read the same resolved chain that
    /// `fallbackEnabled` gated, so switching racing on with fallback off did nothing at
    /// all — silently, with both switches showing as on. And `useLocalModel` overrode
    /// every one of them. Two segmented choices, each shown only when it is a real
    /// choice, can't produce that state.
    @ViewBuilder
    private var routingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("翻译路线")
                .font(Theme.footnoteSemibold)
                .foregroundStyle(.secondary)

            if settings.startChoiceAvailable {
                SegmentedChoice(
                    title: L("从哪开始"),
                    options: [
                        .init(id: RouteStart.local.rawValue, label: L("本地模型")),
                        .init(id: RouteStart.online.rawValue, label: L("在线服务")),
                    ],
                    selection: settings.routeStart.rawValue,
                    onSelect: { settings.routeStart = RouteStart(rawValue: $0) ?? .online },
                    caption: settings.routeStart == .local
                        ? L("先用本地模型翻译，再按翻译键请求在线版本")
                        : L("每次翻译都直接走在线服务")
                )
            } else if settings.onlineAvailable, !settings.localAvailable {
                routingNote(L("填好本地模型后，可以让它先翻，再请求在线版本"))
            } else if settings.localAvailable, !settings.onlineAvailable {
                routingNote(L("目前只有本地模型可用，所有翻译都由它完成"))
            }

            if settings.profiles[0].isUsable && settings.profiles[1].isUsable {
                SegmentedChoice(
                    title: L("两套在线服务"),
                    options: [
                        .init(id: OnlineStrategy.failover.rawValue, label: L("主用优先")),
                        .init(
                            id: OnlineStrategy.concurrent.rawValue,
                            label: L("同时请求"),
                            // Not hidden, disabled with its reason: a missing option
                            // reads as a bug, and the reason is fixable in two fields
                            // right above.
                            disabledReason: settings.concurrentAvailable
                                ? nil
                                : L("其中一套是本机地址，本机几乎必定先答完，比不出快慢")
                        ),
                    ],
                    selection: effectiveOnlineStrategy.rawValue,
                    onSelect: { settings.onlineStrategy = OnlineStrategy(rawValue: $0) ?? .failover },
                    caption: effectiveOnlineStrategy == .failover
                        ? L("先用主用，只有它失败时才换备用")
                        : L("两套同时请求，采用先完成的可用结果；两套均可能计费")
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One value for the whole section: any of these choices can reveal or hide a
        // row, which is the page getting taller or shorter.
        .motion(.layout, value: routingShape)
    }

    /// What the strategy actually resolves to right now. A stored `.concurrent` with a
    /// loopback slot degrades to `.failover` in the route builder, and the page must
    /// show what will happen rather than what was once chosen.
    private var effectiveOnlineStrategy: OnlineStrategy {
        (settings.onlineStrategy == .concurrent && settings.concurrentAvailable) ? .concurrent : .failover
    }

    private struct RoutingShape: Equatable {
        let start: RouteStart
        let strategy: OnlineStrategy
        let startChoice: Bool
        let bothOnline: Bool
        let concurrentAvailable: Bool
    }

    private var routingShape: RoutingShape {
        RoutingShape(
            start: settings.routeStart,
            strategy: effectiveOnlineStrategy,
            startChoice: settings.startChoiceAvailable,
            bothOnline: settings.profiles[0].isUsable && settings.profiles[1].isUsable,
            concurrentAvailable: settings.concurrentAvailable
        )
    }

    private func routingNote(_ text: String) -> some View {
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Toggles

    /// Label left, switch right — so every switch lines up in one column regardless of how
    /// long its label is. Using a native Toggle keeps the label, switch, keyboard focus,
    /// and VoiceOver value as one control instead of two unrelated hit targets.
    private func settingToggle(_ label: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Sound

    /// Sound plays only for the finished translation result and follows the system
    /// output volume. The preview remains available even when the cue is disabled.
    private var soundToggleRow: some View {
        HStack {
            Text("翻译成功音效")
                .onTapGesture { settings.soundEnabled.toggle() }
            Button {
                SoundPlayer.shared.previewSuccess()
            } label: {
                Image(systemName: "play.circle")
                    .font(Theme.bodySmall)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("试听翻译成功音效")
            .accessibilityLabel("试听翻译成功音效")
            Spacer(minLength: 8)
            Toggle("", isOn: $settings.soundEnabled)
                .labelsHidden()
                .accessibilityLabel("翻译成功音效")
        }
    }

    // MARK: - Update check

    /// The auto-check toggle keeps the switch in the same right-hand column as the others;
    /// the quiet "检查更新" button rides just left of it. Only a genuinely available update
    /// spends a second, prominent line — the common case stays one clean row.
    private var updateSettingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("自动检查更新")
                Spacer(minLength: 8)
                updateStatusInline
                Button {
                    updateChecker.check(manual: true)
                } label: {
                    Text("检查更新")
                        .font(Theme.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.fillQuiet))
                }
                .buttonStyle(.plain)
                .disabled(updateChecker.state == .checking)
                Toggle("", isOn: $settings.autoCheckUpdates).labelsHidden()
            }

            if case .available(let version, let url) = updateChecker.state {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(Theme.footnote)
                        Text(String(format: L("有新版本 %@，点击下载"), version))
                            .font(Theme.footnote2Medium)
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        // `.layout`: the update status line appears and disappears, changing the row's
        // height.
        .motion(.layout, value: updateChecker.state)
    }

    /// The short, non-actionable states shown inline next to the check button. An available
    /// update is deliberately excluded here — it gets its own line below.
    @ViewBuilder
    private var updateStatusInline: some View {
        switch updateChecker.state {
        case .checking:
            ProgressView().controlSize(.small).scaleEffect(0.55)
        case .upToDate:
            Text("已是最新")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
        case .failed:
            Text("检查失败")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
        case .idle, .available:
            EmptyView()
        }
    }

    // MARK: - Shortcuts

    /// Entry point into the Shortcuts secondary page (see `PanelState.showShortcuts`) —
    /// keeps this page from ballooning with a full per-action row list.
    private var shortcutsNavRow: some View {
        Button {
            panelState.showShortcuts = true
        } label: {
            HStack {
                Text("快捷键")
                    .font(Theme.body)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(Theme.captionSemibold)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .fill(shortcutsRowHovering ? Theme.fillHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { shortcutsRowHovering = $0 }
        .motion(.micro, value: shortcutsRowHovering)
    }

    // MARK: - Advanced

    /// Per-profile: each slot defaults to expanded if it already holds a routing value
    /// (so a configured setting isn't hidden on first sight), but a manual toggle always
    /// wins after that — collapsing one slot's chevron used to be a no-op whenever that
    /// slot had a value, which read as a fake switch.
    private var showAdvanced: Bool {
        get {
            advancedExpandedOverride[editingIndex] ?? (
                !settings.profiles[safeEditingIndex].providerOrder.trimmingCharacters(in: .whitespaces).isEmpty
                    || settings.profiles[safeEditingIndex].outputProtocolPreference != .automatic
            )
        }
        nonmutating set { advancedExpandedOverride[editingIndex] = newValue }
    }

    /// Provider routing only matters for a handful of gateways and is empty for almost
    /// everyone — collapsed by default so it doesn't cost every user a field + two lines
    /// of explanation.
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showAdvanced.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text("高级选项")
                        .font(Theme.footnoteMedium)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(Theme.caption2Semibold)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Disclosure(isExpanded: showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("输出协议")
                                .font(Theme.footnoteMedium)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Picker("输出协议", selection: $settings.profiles[safeEditingIndex].outputProtocolPreference) {
                                Text("自动（推荐）").tag(TranslationProtocolPreference.automatic)
                                Text("纯文本兼容").tag(TranslationProtocolPreference.plainText)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .controlSize(.small)
                            .accessibilityLabel("输出协议")
                        }
                        Text("自动使用已验证格式；首次不兼容时会改用纯文本并重试一次。")
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // "优先顺序", not "路由": the request only carries OpenRouter's
                    // `provider.order` preference list. It is not `provider.only` and does
                    // not set `allow_fallbacks: false`, so OpenRouter may still serve the
                    // request from a provider that isn't listed here. Calling it routing
                    // promised a guarantee the request never asks for.
                    labeledField(
                        "供应商优先顺序（可选）",
                        hint: "仅 OpenRouter 支持，多个供应商名称用逗号分隔；这些供应商会被优先尝试，都不可用时仍会回退到其他供应商",
                        focused: focusedField == .providerOrder
                    ) {
                        TextField("novita, together", text: $settings.profiles[safeEditingIndex].providerOrder)
                            .textFieldStyle(.plain)
                            .font(Theme.bodyMonospaced)
                            .focused($focusedField, equals: .providerOrder)
                            .accessibilityLabel("供应商优先顺序（可选）")
                    }
                }
                // The stack's own 8pt spacing is above the chevron row, not inside the
                // fold — a collapsed `Disclosure` is zero-height, but a sibling gap is
                // not, and it would leave a hole under a closed section.
                .padding(.top, 8)
            }
        }
        // The chevron, the fields and the panel's own height all move on this one
        // timeline. Both of these sections used to animate nothing but the chevron and
        // let the content pop in at full opacity, because the window was easing an
        // already-eased height and visibly lagged anything that moved. With the window
        // mirroring instead of easing (see PanelController.setContentHeight), there is
        // nothing left to work around.
        .motion(.layout, value: showAdvanced)
    }

    /// Defaults to expanded when there's already an instruction saved (so it isn't
    /// hidden on first sight), but a manual toggle always wins after that — same
    /// override pattern as `showAdvanced`, just not per-slot since the instruction
    /// applies to every profile.
    private var showExtraInstruction: Bool {
        get {
            extraInstructionExpandedOverride
                ?? !settings.extraInstruction.trimmingCharacters(in: .whitespaces).isEmpty
        }
        nonmutating set { extraInstructionExpandedOverride = newValue }
    }

    /// Collapsed by default for the same reason `advancedSection` is: most users never
    /// touch it, so it shouldn't cost every user a field + explanation line by default.
    private var extraInstructionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showExtraInstruction.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text("附加要求（可选）")
                        .font(Theme.footnoteMedium)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(Theme.caption2Semibold)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showExtraInstruction ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Disclosure(isExpanded: showExtraInstruction) {
                // Not `labeledField`: that helper renders its own "附加要求（可选）"
                // label row, which the collapse header above already is — reusing it
                // here would print the same text twice.
                VStack(alignment: .leading, spacing: 5) {
                    TextField("例：commit 统一译作「提交」", text: $settings.extraInstruction, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Theme.body)
                        .lineLimit(1...3)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radiusStandard, style: .continuous)
                                .fill(Theme.fillQuiet)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusStandard, style: .continuous)
                                .strokeBorder(Theme.strokeHairline, lineWidth: 1)
                        )
                    Text("对所有翻译生效，例如统一术语、保留格式")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // See advancedSection: the gap belongs above the fold, not inside it.
                .padding(.top, 8)
            }
        }
        .motion(.layout, value: showExtraInstruction)
    }

    // MARK: - Fields

    // `label`/`hint` arrive as plain String params — literals live at each call site, one
    // level removed from these Text()s — so LocalizedStringKey(...) does the lookup that
    // Text(label) alone wouldn't.
    private func labeledField(
        _ label: String,
        hint: String? = nil,
        focused: Bool = false,
        @ViewBuilder trailing: () -> some View = { EmptyView() },
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(LocalizedStringKey(label))
                    .font(Theme.footnoteMedium)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                trailing()
            }
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusStandard, style: .continuous)
                        .fill(Theme.fillQuiet)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusStandard, style: .continuous)
                        .strokeBorder(
                            focused ? Theme.accent.opacity(0.75) : Theme.strokeHairline,
                            lineWidth: focused ? 1.5 : 1
                        )
                )
            if let hint {
                Text(LocalizedStringKey(hint))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Test connection

    private func cancelTests() {
        Self.cancelConnectionTests(tasks: &testTasks, states: &testStates, generations: &testGenerations)
    }

    static func cancelConnectionTests(
        tasks: inout [Int: Task<Void, Never>],
        states: inout [Int: TestState],
        generations: inout [Int: Int]
    ) {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        for index in Array(states.keys) where states[index] == .testing {
            states[index] = .idle
            generations[index, default: 0] += 1
        }
    }

    private var testRow: some View {
        HStack(spacing: 10) {
            Button {
                runTest()
            } label: {
                HStack(spacing: 5) {
                    if testState == .testing {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(Theme.caption)
                    }
                    Text("测试连接")
                        .font(Theme.bodySmallSemibold)
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.fillQuiet))
                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
                .opacity(settings.profiles[safeEditingIndex].isUsable ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(testState == .testing || !settings.profiles[safeEditingIndex].isUsable)
            .help(L("使用与翻译相同的协议策略，最多发送 2 个短测试请求"))
            .accessibilityHint(L("使用与翻译相同的协议策略，最多发送 2 个短测试请求"))

            Spacer(minLength: 8)

            // The Keychain reassurance now lives up by the API Key label itself — this
            // slot is only for test-in-flight/result feedback, so it's empty until then.
            switch testState {
            case .idle:
                EmptyView()
            case .testing:
                Text("连接中…")
                    .font(Theme.footnote)
                    .foregroundStyle(.tertiary)
            case .success(let result):
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(String(
                        format: L("连接正常 · %d ms · %@"),
                        result.latencyMilliseconds,
                        result.outputProtocol.statusLabel
                    ))
                }
                .font(Theme.footnote2Medium)
                .foregroundStyle(.secondary)
                .transition(.opacity)
            case .failure(let message):
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .font(Theme.footnote)
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }
        }
        // `.layout`: a connection result can wrap onto a second line, so this row's
        // height is not fixed.
        .motion(.layout, value: testState)
    }

    private func runTest() {
        let index = safeEditingIndex
        testTasks[index]?.cancel()
        let generation = (testGenerations[index] ?? 0) + 1
        testGenerations[index] = generation
        testStates[index] = .testing
        let config = settings.profiles[index].config

        let task = Task { @MainActor in
            do {
                let result = try await TranslationService.testConnection(config: config)
                guard !Task.isCancelled, testGenerations[index] == generation else { return }
                testStates[index] = .success(result)
            } catch {
                guard !Task.isCancelled, testGenerations[index] == generation else { return }
                testStates[index] = .failure(error.localizedDescription)
            }
            if testGenerations[index] == generation {
                testTasks[index] = nil
            }
        }
        testTasks[index] = task
    }
}
