import SwiftUI

private struct SettingsBodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct SettingsHeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct SettingsDesiredHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The service detail page's natural height; its own key for the same reason as
/// `ShortcutsHeightKey`.
struct ServiceDetailHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Settings is two levels deep, like System Settings: an overview of grouped rows, and
/// a page per service pushed from its row. Each level is its own instance of this view,
/// so a push animates between two pages instead of swapping content in place.
struct SettingsView: View {
    enum Mode { case overview, service }

    private static let jevServiceIndex = SettingsStore.localProfileIndex + 1
    let mode: Mode

    init(mode: Mode = .overview) {
        self.mode = mode
    }

    @ObservedObject private var localModels = LocalModelManager.shared
    @EnvironmentObject private var engine: TranslationEngine
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var panelState: PanelState
    @EnvironmentObject private var updateChecker: UpdateChecker

    @State private var showKey = false
    @State private var showJevKey = false
    @State private var testStates: [Int: TestState] = [:]
    @State private var testTasks: [Int: Task<Void, Never>] = [:]
    @State private var testGenerations: [Int: Int] = [:]
    @State private var jevTestState: JevTestState = .idle
    @State private var jevTestTask: Task<Void, Never>?
    @State private var jevTestGeneration = 0
    @State private var headerHeight: CGFloat = 0
    @State private var bodyHeight: CGFloat = 0

    private var desiredHeight: CGFloat {
        guard headerHeight > 0, bodyHeight > 0 else { return 0 }
        return min(Self.maximumHeight(availableHeight: panelState.availableHeight), ceil(headerHeight + bodyHeight + 48))
    }

    static func maximumHeight(availableHeight: CGFloat) -> CGFloat {
        min(560, max(180, availableHeight - 24))
    }

    private enum FocusedField: Hashable {
        case baseURL
        case model
        case providerOrder
        case apiKey
        case jevAPIKey
    }

    @FocusState private var focusedField: FocusedField?

    enum TestState: Equatable {
        case idle
        case testing
        case success(TranslationService.ConnectionTestResult)
        case failure(String)
    }

    private enum JevTestState: Equatable {
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

    /// Jev has a service tab but no translation profile slot.
    private var safeEditingIndex: Int {
        settings.profiles.indices.contains(editingIndex) ? editingIndex : 0
    }

    private var isEditingJev: Bool { editingIndex == Self.jevServiceIndex }

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
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 12) {
                if mode == .overview {
                    header
                    categoryPicker
                } else {
                    serviceHeader
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: SettingsHeaderHeightKey.self, value: proxy.size.height)
            })
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    if mode == .service {
                        serviceDetail
                    } else if panelState.settingsSection == .services {
                        servicesOverview
                    } else if panelState.settingsSection == .translation {
                        translationOverview
                    } else {
                        generalOverview
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: SettingsBodyHeightKey.self, value: proxy.size.height)
                })
                .id(mode == .overview ? panelState.settingsSection.rawValue : "service-\(editingIndex)")
            }
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity)
        }
        .padding(18)
        // The viewport follows the host window throughout its animation. Natural
        // content size is a destination request, never a second viewport constraint.
        .frame(maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(SettingsHeaderHeightKey.self) { if $0 > 0 { headerHeight = $0 } }
        .onPreferenceChange(SettingsBodyHeightKey.self) { if $0 > 0 { bodyHeight = $0 } }
        // Each page reports on its own key, so the page leaving during a push can never
        // lend its height to the one arriving (see ShortcutsHeightKey).
        .modifier(DesiredHeightReport(mode: mode, height: desiredHeight))
        .task {
            if !settings.isPreview { await localModels.refresh(settings: settings) }
        }
        .onChange(of: panelState.settingsSection) { _, _ in
            focusedField = nil
            showKey = false
            cancelTests()
            cancelJevTest()
        }
        .onChange(of: settings.jevAPIKey) { _, _ in
            cancelJevTest()
        }
        .onChange(of: settings.profiles) { _, _ in
            cancelTests()
            testStates.removeAll()
        }
        .onChange(of: settings.localModelEnabled) { _, _ in
            cancelTests()
            testStates.removeAll()
        }
        .onChange(of: editingIndex) { _, _ in
            showKey = false
            showJevKey = false
            cancelTests()
            cancelJevTest()
        }
        // Leaving the page mid-recording would otherwise swallow the next keystroke
        // typed into the translator.
        .onDisappear {
            panelState.recordingShortcut = nil
            panelState.shortcutError = nil
            cancelTests()
            cancelJevTest()
        }
    }

    // MARK: - Overview pages

    /// Services as a list — which ones exist, what each is doing — with the details of
    /// any one a click away. The list states the whole route at a glance, which a row of
    /// tabs showing one service at a time could not.
    private var servicesOverview: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: L("翻译服务")) {
                ForEach(Array(serviceOrder.enumerated()), id: \.element) { position, index in
                    if position > 0 { GroupDivider(inset: Self.serviceTextInset) }
                    serviceRow(index)
                }
            }
            SettingsGroup(title: L("文风判断")) {
                serviceRow(Self.jevServiceIndex)
            }
            if hasRoutingChoices {
                SettingsGroup(title: L("翻译路线")) {
                    routingSection
                        .padding(12)
                }
            }
        }
    }

    /// The online services in the order the route tries them, then the local model.
    private var serviceOrder: [Int] {
        let primary = settings.primaryIndex == 1 ? 1 : 0
        return [primary, 1 - primary, SettingsStore.localProfileIndex]
    }

    private var translationOverview: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: L("附加要求")) {
                InstructionEditor(text: $settings.extraInstruction)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
            }
            SettingsGroup(title: L("翻译完成后")) {
                toggleRow("自动复制结果", isOn: $settings.autoCopy)
                GroupDivider()
                toggleRow("长按回车重新翻译", isOn: $settings.holdReturnToRetranslate)
                    .help(L("关闭后隐藏长按提示，并恢复普通回车操作"))
                GroupDivider()
                soundToggleRow
                    .settingsRow()
            }
        }
    }

    private var generalOverview: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup {
                shortcutsNavRow
            }
            SettingsGroup(title: L("隐私与数据")) {
                toggleRow("保存翻译历史", isOn: $settings.saveHistoryEnabled)
                GroupDivider()
                toggleRow("保留输入草稿", isOn: $settings.saveDraftEnabled)
                GroupDivider()
                HStack {
                    Text("当前草稿")
                    Spacer(minLength: 8)
                    Button(L("清除")) { engine.clearDraft() }
                        .controlSize(.small)
                        .disabled(engine.input.isEmpty)
                }
                .font(Theme.body)
                .settingsRow()
            }
            if let error = engine.persistenceError {
                footnote(error, warning: true)
            }
            SettingsGroup(title: L("启动与更新")) {
                toggleRow("登录时启动", isOn: $settings.launchAtLogin)
                GroupDivider()
                updateSettingRow
                    .settingsRow()
            }
            if let error = settings.launchAtLoginError {
                footnote(error, warning: true)
            }
            if panelState.globalHotkeyFailed {
                footnote(L("全局呼出快捷键注册失败，可能被其他应用占用；换一个组合键，或点菜单栏图标呼出"), warning: true)
            }
        }
    }

    private func footnote(_ text: String, warning: Bool = false) -> some View {
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    // MARK: - Service rows

    /// Where a service row's text starts: the row inset, the status dot, and its gap.
    private static let serviceTextInset: CGFloat = 12 + 6 + 10

    @State private var hoveredService: Int?

    private func serviceRow(_ index: Int) -> some View {
        let summary = serviceSummary(index)
        return Button {
            editingIndex = index
            panelState.showServiceDetail = true
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(summary.ready ? AnyShapeStyle(Theme.success) : AnyShapeStyle(Color.secondary.opacity(0.35)))
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(summary.title)
                        if let name = summary.name {
                            Text(name).foregroundStyle(.secondary)
                        }
                    }
                    .font(Theme.body)
                    .lineLimit(1)
                    Text(summary.detail)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(Theme.captionSemibold)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hoveredService == index ? Theme.fillQuiet : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredService = index } else if hoveredService == index { hoveredService = nil }
        }
        .motion(.micro, value: hoveredService == index)
        .accessibilityLabel([summary.title, summary.name, summary.detail].compactMap { $0 }.joined(separator: ", "))
    }

    private struct ServiceSummary {
        let title: String
        let name: String?
        let detail: String
        let ready: Bool
    }

    /// One line per service that says what it is doing in the route right now.
    private func serviceSummary(_ index: Int) -> ServiceSummary {
        if index == Self.jevServiceIndex {
            let ready = !settings.jevAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return ServiceSummary(title: "Jev", name: nil,
                                  detail: ready ? L("已配置") : L("未配置"),
                                  ready: ready)
        }
        if index == SettingsStore.localProfileIndex {
            let model = settings.profiles[index].model.trimmingCharacters(in: .whitespaces)
            let detail = settings.localAvailable ? model
                : (settings.localModelEnabled ? L("未就绪") : L("已关闭"))
            return ServiceSummary(title: L("本地模型"), name: nil, detail: detail,
                                  ready: settings.localAvailable)
        }
        let profile = settings.profiles[index]
        let primary = settings.primaryIndex == index
        let concurrent = settings.onlineStrategy == .concurrent && settings.concurrentAvailable
        let title = concurrent ? L("在线服务") : (primary ? L("主用") : L("备用"))
        guard profile.isUsable else {
            return ServiceSummary(title: title, name: nil, detail: L("未配置"), ready: false)
        }
        return ServiceSummary(title: title, name: settings.label(for: index),
                              detail: profile.model.trimmingCharacters(in: .whitespaces),
                              ready: settings.isSlotAvailable(index))
    }

    /// Whether the route has anything to choose.
    private var hasRoutingChoices: Bool {
        settings.startChoiceAvailable || (settings.profiles[0].isUsable && settings.profiles[1].isUsable)
    }

    // MARK: - Service detail page

    private var serviceTitle: String {
        if isEditingJev { return L("Jev 文风判断") }
        if isEditingLocalSlot { return L("本地模型") }
        if settings.onlineStrategy == .concurrent && settings.concurrentAvailable { return L("在线服务") }
        return settings.primaryIndex == editingIndex ? L("主用服务") : L("备用服务")
    }

    private var serviceHeader: some View {
        HStack(spacing: 8) {
            backButton { panelState.showServiceDetail = false }
            Text(serviceTitle)
                .font(Theme.title)
            Spacer()
            serviceRoleAction
        }
    }

    @ViewBuilder
    private var serviceDetail: some View {
        if isEditingJev {
            jevSection
        } else {
            VStack(alignment: .leading, spacing: 12) {
                serviceFields
                testRow
                advancedSection
            }
        }
    }

    private var serviceFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isEditingLocalSlot {
                localModelPicker
            } else {
            labeledField("接口地址", focused: focusedField == .baseURL) {
                TextField(
                    "接口地址", text: $settings.profiles[safeEditingIndex].baseURL,
                    prompt: Self.placeholder("https://api.example.com/v1")
                )
                .textFieldStyle(.plain)
                .font(Theme.bodyMonospaced)
                .focused($focusedField, equals: .baseURL)
                .accessibilityLabel("接口地址")
            }
            labeledField("模型", focused: focusedField == .model) {
                TextField("模型", text: $settings.profiles[safeEditingIndex].model, prompt: Self.placeholder("model-name"))
                    .textFieldStyle(.plain)
                    .font(Theme.bodyMonospaced)
                    .focused($focusedField, equals: .model)
                    .accessibilityLabel("模型")
            }
            }
            // Local (loopback) servers take no key, so they get no key field.
            if !isCurrentProfileLocal {
                labeledField("API Key", focused: focusedField == .apiKey) {
                    Image(systemName: "lock.fill")
                        .font(Theme.caption2)
                        .foregroundStyle(.secondary)
                        .help(L("API Key 仅保存在本机钥匙串，只发送给你配置的 API 服务"))
                        .accessibilityLabel(L("API Key 仅保存在本机钥匙串，只发送给你配置的 API 服务"))
                } content: {
                    HStack(spacing: 6) {
                        Group {
                            if showKey {
                                TextField("API Key", text: $settings.profiles[safeEditingIndex].apiKey, prompt: Self.placeholder("sk-…"))
                            } else {
                                SecureField("API Key", text: $settings.profiles[safeEditingIndex].apiKey, prompt: Self.placeholder("sk-…"))
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
    }

    private func backButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(Theme.bodySmallSemibold)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.fillQuiet))
        }
        .buttonStyle(.plain)
        .help(settings.commandLabel(L("返回"), action: .close))
    }

    /// Label left, switch right, as one native control.
    private func toggleRow(_ label: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(Theme.body)
        .settingsRow()
    }

    // MARK: - Header

    private var localModelPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { settings.localModelEnabled },
                set: { localModels.setEnabled($0, settings: settings) }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("启用本地模型").font(Theme.bodySmallSemibold)
                    HStack(spacing: 5) {
                        if localModels.isSwitching {
                            ProgressView().controlSize(.mini)
                        } else {
                            Circle()
                                .fill(settings.localAvailable ? AnyShapeStyle(Theme.success) : AnyShapeStyle(Color.secondary.opacity(0.4)))
                                .frame(width: 5, height: 5)
                        }
                        Text(localModels.status).font(Theme.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(localModels.isSwitching || engine.isTranslating || engine.escalating || testState == .testing)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Theme.radiusStandard, style: .continuous).fill(Theme.fillQuiet))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusStandard, style: .continuous).strokeBorder(Theme.strokeHairline, lineWidth: 1))

            HStack {
                Text("使用的模型").font(Theme.footnoteMedium).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await localModels.refresh(settings: settings) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("刷新模型列表")
                .disabled(localModels.isSwitching)
            }
            Picker("本地模型", selection: Binding(
                get: { localModels.selectedID },
                set: { localModels.select($0, settings: settings) }
            )) {
                Text("选择模型").tag("")
                ForEach(localModels.models) { model in
                    Text(model.label).tag(model.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(localModels.isSwitching || engine.isTranslating || engine.escalating || testState == .testing)
            if let error = localModels.error {
                Text(error).font(Theme.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if localModels.state == .failed || localModels.error != nil {
                Button("重试") { localModels.setEnabled(settings.localModelEnabled, settings: settings) }
                    .disabled(localModels.isSwitching || engine.isTranslating || engine.escalating || testState == .testing)
            }
        }
    }

    @ViewBuilder
    private var categoryPicker: some View {
        if #available(macOS 26.0, *) {
            SettingsCategoryPicker(selection: $panelState.settingsSection)
                .controlSize(.extraLarge)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            SettingsCategoryPicker(selection: $panelState.settingsSection)
                .controlSize(.large)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            backButton { panelState.showSettings = false }

            Text("设置")
                .font(Theme.title)

            Spacer()

            Text("Tusi v\(appVersion)")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// Read from the bundle so it can never drift from the shipped version.
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    // MARK: - Slot roles

    /// The one role change a service page offers, as a link in its header: make this
    /// the primary, or choose whether the local model or the online services go first.
    /// Nothing is shown when there is nothing to change.
    @ViewBuilder
    private var serviceRoleAction: some View {
        if isEditingLocalSlot {
            if settings.startChoiceAvailable {
                roleActionButton(settings.routeStart == .local ? L("改为先用在线") : L("设为起点")) {
                    settings.routeStart = settings.routeStart == .local ? .online : .local
                }
            }
        } else if !isEditingJev,
                  !(settings.onlineStrategy == .concurrent && settings.concurrentAvailable),
                  settings.primaryIndex != editingIndex {
            roleActionButton(L("设为主用")) { settings.primaryIndex = editingIndex }
        }
    }

    private func roleActionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(Theme.footnoteMedium)
            .foregroundStyle(Theme.accent)
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
            if settings.startChoiceAvailable {
                SegmentedChoice(
                    title: L("从哪开始"),
                    options: [
                        .init(id: RouteStart.local.rawValue, label: L("本地模型")),
                        .init(id: RouteStart.online.rawValue, label: L("在线服务")),
                    ],
                    selection: settings.routeStart.rawValue,
                    onSelect: { settings.routeStart = RouteStart(rawValue: $0) ?? .online }
                )
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
                    onSelect: { settings.onlineStrategy = OnlineStrategy(rawValue: $0) ?? .failover }
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
                .toggleStyle(.switch)
                .controlSize(.mini)
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
                Toggle("", isOn: $settings.autoCheckUpdates)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
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
            ProgressView().controlSize(.mini)
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
            HStack(spacing: 8) {
                Text("快捷键")
                    .font(Theme.body)
                Spacer()
                // The one binding people need to remember, so it is worth a glance here.
                if let summon = settings.shortcut(.summon) {
                    Text(summon.display)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(Theme.captionSemibold)
                    .foregroundStyle(.tertiary)
            }
            .settingsRow()
            .background(shortcutsRowHovering ? Theme.fillQuiet : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { shortcutsRowHovering = $0 }
        .motion(.micro, value: shortcutsRowHovering)
    }

    @State private var shortcutsRowHovering = false

    // MARK: - Advanced

    /// Advanced configuration stays out of the default service form, including when
    /// a profile already has a provider preference or compatibility override.
    private var showAdvanced: Bool {
        get {
            panelState.settingsAdvancedProfiles.contains(editingIndex)
        }
        nonmutating set {
            if newValue { panelState.settingsAdvancedProfiles.insert(editingIndex) }
            else { panelState.settingsAdvancedProfiles.remove(editingIndex) }
        }
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
                    if isEditingLocalSlot {
                        labeledField("接口地址", focused: focusedField == .baseURL) {
                            TextField("接口地址", text: $settings.profiles[safeEditingIndex].baseURL, prompt: Self.placeholder("http://127.0.0.1:8080/v1"))
                                .textFieldStyle(.plain).font(Theme.bodyMonospaced)
                                .focused($focusedField, equals: .baseURL)
                        }
                        labeledField("模型", focused: focusedField == .model) {
                            TextField("模型", text: $settings.profiles[safeEditingIndex].model, prompt: Self.placeholder("model-name"))
                                .textFieldStyle(.plain).font(Theme.bodyMonospaced)
                                .focused($focusedField, equals: .model)
                        }
                    }
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
                    }

                    // "优先顺序", not "路由": the request only carries OpenRouter's
                    // `provider.order` preference list. It is not `provider.only` and does
                    // not set `allow_fallbacks: false`, so OpenRouter may still serve the
                    // request from a provider that isn't listed here. Calling it routing
                    // promised a guarantee the request never asks for.
                    labeledField(
                        "供应商优先顺序（可选）",
                        focused: focusedField == .providerOrder
                    ) {
                        TextField("供应商优先顺序（可选）", text: $settings.profiles[safeEditingIndex].providerOrder, prompt: Self.placeholder("novita, together"))
                            .textFieldStyle(.plain)
                            .font(Theme.bodyMonospaced)
                            .focused($focusedField, equals: .providerOrder)
                            .accessibilityLabel("供应商优先顺序（可选）")
                    }
                    .help(L("仅 OpenRouter 支持，多个供应商名称用逗号分隔；这些供应商会被优先尝试，都不可用时仍会回退到其他供应商"))
                }
                // The stack's own 8pt spacing is above the chevron row, not inside the
                // fold — a collapsed `Disclosure` is zero-height, but a sibling gap is
                // not, and it would leave a hole under a closed section.
                .padding(.top, 8)
                .disabled(isEditingLocalSlot && localModels.isSwitching)
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

    private var jevSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            labeledField(
                "API Key",
                focused: focusedField == .jevAPIKey
            ) {
                Image(systemName: "lock.fill")
                    .font(Theme.caption2)
                    .foregroundStyle(.secondary)
                    .help(L("Key 保存在本机钥匙串；选择智能文风时将待译文本发送给 Jev"))
            } content: {
                HStack(spacing: 6) {
                    Group {
                        if showJevKey {
                            TextField("Jev API Key", text: $settings.jevAPIKey, prompt: Self.placeholder("Jev API Key"))
                        } else {
                            SecureField("Jev API Key", text: $settings.jevAPIKey, prompt: Self.placeholder("Jev API Key"))
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(Theme.bodyMonospaced)
                    .focused($focusedField, equals: .jevAPIKey)

                    if settings.keychainSaved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Button {
                        showJevKey.toggle()
                    } label: {
                        Image(systemName: showJevKey ? "eye.slash" : "eye")
                            .font(Theme.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(showJevKey ? "隐藏" : "显示")
                    .accessibilityLabel(showJevKey ? "隐藏" : "显示")
                }
            }
            if let error = settings.keychainError {
                Text(error)
                    .font(Theme.caption)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Button {
                    testJevConnection()
                } label: {
                    HStack(spacing: 5) {
                        if jevTestState == .testing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "bolt.fill")
                        }
                        Text("测试连接")
                    }
                    .foregroundStyle(Theme.accent)
                }
                .controlSize(.large)
                .disabled(jevTestState == .testing || settings.jevAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .modifier(TestConnectionButtonStyle())

                Spacer(minLength: 8)
                switch jevTestState {
                case .idle:
                    EmptyView()
                case .testing:
                    Text("连接中…").foregroundStyle(.tertiary)
                case .success(let milliseconds):
                    Label(String(format: L("连接正常 · %d ms"), milliseconds), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failure(let message):
                    Label(message, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(Theme.footnote)
        }
    }

    private func cancelJevTest() {
        jevTestTask?.cancel()
        jevTestTask = nil
        jevTestGeneration += 1
        jevTestState = .idle
    }

    private func testJevConnection() {
        cancelJevTest()
        let generation = jevTestGeneration
        let key = settings.jevAPIKey
        jevTestState = .testing
        jevTestTask = Task { @MainActor in
            do {
                let milliseconds = try await JevToneService.testConnection(key: key)
                guard !Task.isCancelled, generation == jevTestGeneration else { return }
                jevTestState = .success(milliseconds)
            } catch {
                guard !Task.isCancelled, generation == jevTestGeneration else { return }
                jevTestState = .failure(error.localizedDescription)
            }
            jevTestTask = nil
        }
    }

    // MARK: - Fields

    /// A field's example value. Verbatim, because a `LocalizedStringKey` is parsed as
    /// Markdown and a bare URL in it becomes a blue link — which is how the empty base
    /// URL field used to look like it had already been filled in. Tertiary, so an
    /// example can never be mistaken for a value.
    static func placeholder(_ example: String) -> Text {
        Text(verbatim: example).foregroundStyle(.tertiary)
    }

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

    private var connectionTestCommand: some View {
        Button {
            runTest()
        } label: {
            HStack(spacing: 5) {
                if testState == .testing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "bolt.fill")
                }
                Text("测试连接")
            }
            .foregroundStyle(Theme.accent)
        }
        .controlSize(.large)
        .disabled(testState == .testing || !settings.isSlotAvailable(safeEditingIndex))
        .help(L("使用与翻译相同的协议策略，最多发送 2 个短测试请求"))
        .accessibilityHint(L("使用与翻译相同的协议策略，最多发送 2 个短测试请求"))
    }

    private var testRow: some View {
        HStack(spacing: 10) {
            connectionTestCommand.modifier(TestConnectionButtonStyle())

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
                        .foregroundStyle(.orange)
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
        guard settings.isSlotAvailable(index) else { return }
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

/// Both Test Connection buttons — a service slot's and Jev's — in one style: a glass
/// capsule on macOS 26, a bordered button before it.
private struct TestConnectionButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass).buttonBorderShape(.capsule)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

// MARK: - Grouped rows

/// A titled group of rows on one rounded surface, as in System Settings: the title says
/// what the rows are about, the footer says what they do, and the surface says they
/// belong together — no divider lines between sections needed.
private struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(Theme.footnoteMedium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.fillQuiet)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusGroup, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusGroup, style: .continuous)
                    .strokeBorder(Theme.strokeHairline, lineWidth: 1)
            )
            if let footer {
                Text(footer)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// The hairline between two rows of a group, inset to the rows' text.
private struct GroupDivider: View {
    var inset: CGFloat = 12

    var body: some View {
        Rectangle()
            .fill(Theme.strokeHairline)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

private extension View {
    /// A group row's insets and minimum height.
    func settingsRow() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }
}

/// Reports the settings page's height on the key belonging to its level.
private struct DesiredHeightReport: ViewModifier {
    let mode: SettingsView.Mode
    let height: CGFloat

    func body(content: Content) -> some View {
        switch mode {
        case .overview: content.preference(key: SettingsDesiredHeightKey.self, value: height)
        case .service: content.preference(key: ServiceDetailHeightKey.self, value: height)
        }
    }
}
