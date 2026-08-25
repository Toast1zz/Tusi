import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var panelState: PanelState
    @EnvironmentObject private var updateChecker: UpdateChecker
    @EnvironmentObject private var engine: TranslationEngine

    @State private var showKey = false
    @State private var testStates: [Int: TestState] = [:]
    @State private var testTasks: [Int: Task<Void, Never>] = [:]
    @State private var testGenerations: [Int: Int] = [:]
    @State private var shortcutsRowHovering = false
    @State private var advancedExpandedOverride: [Int: Bool] = [:]

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
        case success(Int)
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
                            .fill(Color.primary.opacity(0.05))
                    )
                } else {
                    labeledField("API Key", focused: focusedField == .apiKey) {
                        HStack(spacing: 5) {
                            Image(systemName: "lock.fill")
                                .font(Theme.caption2)
                            Text("API Key 仅保存在本机钥匙串，不会上传")
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
                                    .transition(.scale(scale: 0.7).combined(with: .opacity))
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
                        .animation(.snappy(duration: Theme.durationFast), value: settings.keychainSaved)
                        .accessibilityLabel("API Key")
                    }
                }

                if let error = settings.keychainError {
                    Text(error)
                        .font(Theme.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            testRow

            SoftDivider()

            labeledField("附加要求（可选）", hint: "对所有翻译生效，例如统一术语、保留格式") {
                TextField("例：commit 统一译作「提交」", text: $settings.extraInstruction, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .lineLimit(1...3)
            }

            SoftDivider()

            shortcutsNavRow

            VStack(alignment: .leading, spacing: 10) {
                settingToggle("主用失败时自动切换到备用", isOn: $settings.fallbackEnabled)
                settingToggle("翻译完成后自动复制", isOn: $settings.autoCopy)
                settingToggle("登录时启动", isOn: $settings.launchAtLogin)
                updateSettingRow
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(Theme.body)

            // Its own row (not folded into the group above) because the caption below
            // is load-bearing: this setting doubles outbound requests whenever both
            // slots are usable remote APIs, and that cost trade-off must be visible at
            // the point of opting in, not buried in a tooltip.
            VStack(alignment: .leading, spacing: 6) {
                settingToggle("主备同时请求，取最快结果", isOn: $settings.raceFastestEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(Theme.body)
                Text("仅当主备都填了远程 API 时生效，本地模型不参与竞速。会让每次翻译同时向两边发起请求，请留意计费。")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The sound preference gets its own row so it reads as a distinct sense
            // channel, not a translation behavior. Switching it off is deliberately
            // silent (muting must not announce itself); switching it on plays one quiet
            // toggle-on cue as confirmation.
            VStack(alignment: .leading, spacing: 10) {
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
        .padding(18)
        .onChange(of: settings.profiles) { _, _ in
            testTasks.values.forEach { $0.cancel() }
            testTasks.removeAll()
            testStates.removeAll()
            testGenerations.removeAll()
        }
        .onChange(of: editingIndex) { _, _ in
            showKey = false
            testTasks.values.forEach { $0.cancel() }
            testTasks.removeAll()
        }
        // Leaving the page mid-recording would otherwise swallow the next keystroke
        // typed into the translator.
        .onDisappear {
            panelState.recordingShortcut = nil
            panelState.shortcutError = nil
            testTasks.values.forEach { $0.cancel() }
            testTasks.removeAll()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.snappy(duration: Theme.durationSlow)) {
                    panelState.showSettings = false
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(Theme.bodySmallSemibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("返回 (Esc)")

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
                }
                Spacer(minLength: 0)
            }

            if isEditingLocalSlot {
                // No primary/backup role applies here: the only thing this slot does
                // is answer to this one switch. No separate manual-trigger UI exists
                // anywhere else in the panel — this toggle is the entire contract.
                VStack(alignment: .leading, spacing: 4) {
                    settingToggle("翻译时使用这个模型", isOn: $settings.useLocalModel)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(Theme.caption2Medium)
                    // Deliberately not disabled when the slot is empty: flipping the
                    // switch is harmless either way (translate() already shows a clear
                    // "not configured" error if fired with nothing filled in below),
                    // and a plain Text + .onTapGesture toggle target (see
                    // settingToggle) doesn't reliably honor `.disabled()` anyway.
                    Text(settings.profiles[SettingsStore.localProfileIndex].isUsable
                         ? "开启后 ⏎ 翻译只会用这个模型，不再走主用/备用或竞速；关闭后不受影响"
                         : "开启后还需要填好下面的接口地址和模型")
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 6) {
                    if settings.primaryIndex == editingIndex {
                        Label("当前为主用，优先使用这套", systemImage: "checkmark.seal.fill")
                            .font(Theme.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Button {
                            withAnimation(.snappy(duration: Theme.durationStandard)) {
                                settings.primaryIndex = editingIndex
                            }
                        } label: {
                            Label("设为主用", systemImage: "arrow.up.circle")
                                .font(Theme.caption2Medium)
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)

                        Text(settings.fallbackEnabled ? "· 现在是主用失败后的备用" : "· 备用已关闭，这套不会被使用")
                            .font(Theme.caption)
                            .foregroundStyle(.quaternary)
                    }
                }
            }
        }
    }

    private func slotTab(_ index: Int) -> some View {
        let selected = editingIndex == index
        let isPrimary = settings.primaryIndex == index
        let isLocal = index == SettingsStore.localProfileIndex
        return Button {
            withAnimation(.snappy(duration: Theme.durationStandard)) { editingIndex = index }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(settings.profiles[index].isUsable
                          ? AnyShapeStyle(Theme.success)
                          : AnyShapeStyle(Color.secondary.opacity(0.35)))
                    .frame(width: 5, height: 5)
                Text(isLocal ? "本地模型" : (isPrimary ? "主用" : "备用"))
                    .font(Theme.footnote2Semibold)
                Text(settings.label(for: index))
                    .font(Theme.caption)
                    .opacity(0.7)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(
                    selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(0.055))
                )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toggles

    /// Label left, switch right — so every switch lines up in one column regardless of how
    /// long its label is. Label is also tappable for accessibility.
    private func settingToggle(_ label: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .onTapGesture { isOn.wrappedValue.toggle() }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .accessibilityLabel(label)
        }
    }

    // MARK: - Sound

    /// The sound switch. Sound plays only for the finished translation result, so this
    /// switch is a plain on/off for that cue. The label is tappable for accessibility,
    /// same as the other rows. The small "试听" button next to it plays the cue even
    /// when the switch is off, so the user can judge the sound before enabling it.
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
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
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
        .animation(.snappy(duration: Theme.durationStandard), value: updateChecker.state)
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
            withAnimation(.snappy(duration: Theme.durationSlow)) {
                panelState.showShortcuts = true
            }
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
                    .fill(shortcutsRowHovering ? Color.primary.opacity(0.055) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { shortcutsRowHovering = $0 }
        .animation(Theme.snappy(Theme.durationFast), value: shortcutsRowHovering)
    }

    // MARK: - Advanced

    /// Per-profile: each slot defaults to expanded if it already holds a routing value
    /// (so a configured setting isn't hidden on first sight), but a manual toggle always
    /// wins after that — collapsing one slot's chevron used to be a no-op whenever that
    /// slot had a value, which read as a fake switch.
    private var showAdvanced: Bool {
        get {
            advancedExpandedOverride[editingIndex]
                ?? !settings.profiles[safeEditingIndex].providerOrder.trimmingCharacters(in: .whitespaces).isEmpty
        }
        nonmutating set { advancedExpandedOverride[editingIndex] = newValue }
    }

    /// Provider routing only matters for a handful of gateways and is empty for almost
    /// everyone — collapsed by default so it doesn't cost every user a field + two lines
    /// of explanation.
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                // Only the chevron animates here — the field below deliberately doesn't
                // (see its comment): cross-fading it fights the panel's own window-resize
                // animation, which runs on AppKit's timeline, not SwiftUI's, and the two
                // easing curves never quite track each other. Letting the field pop in
                // instantly and having the window's resize be the only motion sidesteps
                // that mismatch entirely.
                withAnimation(.snappy(duration: Theme.durationStandard)) { showAdvanced.toggle() }
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

            if showAdvanced {
                labeledField(
                    "供应商路由（可选）",
                    hint: "仅 OpenRouter 支持，多个供应商名称用逗号分隔",
                    focused: focusedField == .providerOrder
                ) {
                    TextField("novita, together", text: $settings.profiles[safeEditingIndex].providerOrder)
                        .textFieldStyle(.plain)
                        .font(Theme.bodyMonospaced)
                        .focused($focusedField, equals: .providerOrder)
                        .accessibilityLabel("供应商路由（可选）")
                }
                .transition(.identity)
            }
        }
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
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusStandard, style: .continuous)
                        .strokeBorder(
                            focused ? Theme.accent.opacity(0.75) : Color.primary.opacity(0.07),
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
                .background(Capsule().fill(Color.primary.opacity(0.055)))
                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
                .opacity(settings.profiles[safeEditingIndex].isUsable ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(testState == .testing || !settings.profiles[safeEditingIndex].isUsable)

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
            case .success(let ms):
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(String(format: L("连接正常 · %d ms"), ms))
                }
                .font(Theme.footnote2Medium)
                .foregroundStyle(.secondary)
                .transition(.opacity)
            case .failure(let message):
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .lineLimit(2)
                }
                .font(Theme.footnote)
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }
        }
        .animation(.snappy(duration: Theme.durationStandard), value: testState)
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
                let ms = try await TranslationService.testConnection(config: config)
                guard !Task.isCancelled, testGenerations[index] == generation else { return }
                testStates[index] = .success(ms)
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
