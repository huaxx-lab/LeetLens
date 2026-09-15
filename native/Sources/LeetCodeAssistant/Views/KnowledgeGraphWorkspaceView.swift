import AppKit
import SwiftUI

/// 知识脑图。
///
/// 分两层：派生层（知识路径 + 题目 + AI 讲解）由学习记录现算，
/// 人工层（坐标、链接、笔记卡片）存在 `knowledge-graph.json` 里，合流后交给画布渲染。
///
/// 依赖是单向的——学习记录 → 学习包（讲解）→ 派生节点 → 人工层。
/// 所以删掉一个知识点，后面几层会自己塌掉：派生节点没了，
/// `reconciled` 把挂在死节点上的笔记和链接一起清掉，不会留下指向空气的虚线。
///
/// 编辑全部发生在画布里的弹窗中。以前有个右侧栏，不管有没有选中都占着画布宽度，
/// 空着的时候就是一大块白板。
struct KnowledgeGraphWorkspaceView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore

    @State private var overlay = KnowledgeGraphOverlay.empty
    @State private var selectedNodeID: String?
    @State private var searchText = ""
    @State private var isLinking = false
    @State private var linkDirected = false
    @State private var reloadToken = 0
    @State private var fitRequest = 0
    @State private var focusRequest: String?
    /// 同一个节点可能被反复请求对焦（离开脑图再点同一道题跳回来）。只比对 id
    /// 的话第二次就被当成"没变"吞掉，所以额外带一个递增票据。
    @State private var focusToken = 0
    /// 正在生成讲解的节点。画布拿它显示「生成中…」，同时挡住重复点击。
    @State private var busyNodes: Set<String> = []
    @State private var errorText = ""
    @State private var isLoaded = false

    private var derived: KnowledgeGraphElements {
        KnowledgeGraphBuilder.derive(records: dataStore.activeLearningRecords)
    }

    private var elements: KnowledgeGraphElements {
        KnowledgeGraphBuilder.merge(derived: derived, overlay: overlay)
    }

    var body: some View {
        canvas
            .background(AppDesign.ColorToken.canvas)
            .task(id: dataStore.activeLearningRevision) {
                await load()
                // 进页面时带着目标进来的（题库/复习页点"在脑图中查看"），
                // 那次赋值发生在本视图存在之前，onChange 根本不会触发。
                focusSelectedRecord()
            }
            .onChange(of: workspace.selectedLearningRecordID) { _, _ in
                focusSelectedRecord()
            }
            // 目标没变、只是又从别的页面跳回来时，上面那条不触发；
            // 这条按"重新进入脑图"这个事件补一次。
            .onChange(of: workspace.selectedSection) { _, section in
                guard section == .knowledge else { return }
                focusSelectedRecord()
            }
    }

    /// 把镜头对到 workspace 选中的那道题上。
    private func focusSelectedRecord() {
        guard isLoaded, let recordID = workspace.selectedLearningRecordID else { return }
        let id = KnowledgeGraphBuilder.nodeID(forRecord: recordID)
        guard elements.nodes.contains(where: { $0.id == id }) else { return }
        selectedNodeID = id
        focusRequest = id
        focusToken += 1
    }

    // MARK: - 画布

    private var canvas: some View {
        // 工具栏并进列头那一行（一列一行头部），不再单独占一条、也不浮在画布上压住卡片。
        VStack(spacing: 0) {
            Hairline()
            graphCanvas
        }
        .workspaceHeader(id: "knowledge", hidesTitle: false) {
            toolbarLeading
        } trailing: {
            toolbarTrailing
        }
    }

    /// 和 graph.html 里的 `--paper` 同一个颜色。SwiftUI 这层不铺成一样的，
    /// WebView 还没绘制完的那一帧就是一片白。
    private static let paper = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.137, green: 0.137, blue: 0.122, alpha: 1)
                : NSColor(srgbRed: 0.914, green: 0.898, blue: 0.855, alpha: 1)
        }
    )

    private var graphCanvas: some View {
        ZStack(alignment: .bottom) {
            Self.paper.ignoresSafeArea()
            KnowledgeGraphWebView(
                elements: elements,
                childOrder: overlay.childOrder,
                collapsed: overlay.collapsed,
                noteCards: overlay.noteCards,
                busyNodes: busyNodes.sorted(),
                searchText: searchText,
                isLinking: isLinking,
                linkDirected: linkDirected,
                reloadToken: reloadToken,
                focusRequest: focusRequest,
                focusToken: focusToken,
                fitRequest: fitRequest,
                onSelect: { selectedNodeID = $0.isEmpty ? nil : $0 },
                onActivate: activate(nodeID:),
                onAction: { id, action in
                    guard action == "practice",
                          let recordID = elements.nodes.first(where: { $0.id == id })?.recordID
                    else { return }
                    workspace.selectedLearningRecordID = recordID
                    workspace.selectedSection = .review
                },
                onReorder: { parentID, order in
                    Task { await mutate { $0.childOrder[parentID] = order } }
                },
                onLinkCreated: { source, target, directed in
                    Task { await createLink(source: source, target: target, directed: directed) }
                },
                onNoteAdded: { anchorID, text in
                    Task {
                        await mutate { current in
                            current.noteCards.append(
                                .init(id: "note:\(UUID().uuidString)", anchorID: anchorID, text: text)
                            )
                        }
                    }
                },
                onNoteUpdated: { id, text in
                    // 清空 = 删除。省得再问一次"要不要删"。
                    Task {
                        await mutate { current in
                            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                current.noteCards.removeAll { $0.id == id }
                            } else if let index = current.noteCards.firstIndex(where: { $0.id == id }) {
                                current.noteCards[index].text = text
                            }
                        }
                    }
                },
                onNoteRemoved: { id in
                    Task { await mutate { $0.noteCards.removeAll { note in note.id == id } } }
                },
                onLessonRequested: { id, force in
                    Task { await generateLesson(nodeID: id, force: force) }
                },
                onLinkRemoved: { id in
                    Task { await mutate { $0.links.removeAll { link in link.id == id } } }
                },
                onCollapseChanged: { ids in
                    Task { await mutate { $0.collapsed = ids } }
                },
                onLayoutReset: {
                    Task { await mutate { $0.childOrder = [:] } }
                },
                onLinkModeExited: {
                    // 画布上点空白退出了连线，工具栏那颗按钮也得灭掉。
                    isLinking = false
                    selectedNodeID = nil
                }
            )
            .ignoresSafeArea()

            if !errorText.isEmpty {
                errorBanner
            }
        }
    }

    private var errorBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppDesign.ColorToken.warning)
            Text(errorText)
                .font(.appScaled(size: 12))
                .lineLimit(2)
            Button {
                errorText = ""
            } label: {
                Image(systemName: "xmark").font(.appScaled(size: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassCapsule()
        .padding(.bottom, 18)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var toolbarLeading: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(AppDesign.Typography.micro)
                    .foregroundStyle(.tertiary)
                TextField("搜索节点", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(AppDesign.Typography.aux)
                    .frame(width: AppDesign.Size.scaledControl(120))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: AppDesign.Size.toolbarControl - 2)
            .quietCapsule()

            // 连线：单向和双向都画虚线，靠箭头个数区分。
            Menu {
                Button("双向链接 ↔") { linkDirected = false; isLinking = true }
                Button("单向链接 →") { linkDirected = true; isLinking = true }
                if isLinking {
                    Divider()
                    Button("退出连线") { isLinking = false }
                }
            } label: {
                Label(isLinking ? (linkDirected ? "单向连线中" : "双向连线中") : "连线", systemImage: "link")
                    .font(AppDesign.Typography.auxEmphasis)
                    .foregroundStyle(isLinking ? Color.accentColor : .secondary)
                    .padding(.horizontal, 10)
                    .frame(height: AppDesign.Size.toolbarControl - 2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: AppDesign.Size.scaledControl(isLinking ? 104 : 66), height: AppDesign.Size.toolbarControl - 2)
            .background(isLinking ? Color.accentColor.opacity(0.12) : AppDesign.ColorToken.inlineFill, in: Capsule())
            .help("连好后点虚线可以跳转或删除")

            // 展开 / 收起是大图能不能看的关键。列窄时只留图标，不把整行撑出去。
            ViewThatFits(in: .horizontal) {
                layoutButtons(showsTitles: true)
                layoutButtons(showsTitles: false)
            }
        }
    }

    private func layoutButtons(showsTitles: Bool) -> some View {
        HStack(spacing: 2) {
            toolbarButton("展开全部", systemImage: "arrow.up.left.and.arrow.down.right", showsTitle: showsTitles) {
                Task { await mutate { $0.collapsed = [] } }
            }
            toolbarButton("只看主干", systemImage: "arrow.down.right.and.arrow.up.left", showsTitle: showsTitles) {
                let ids = KnowledgeGraphBuilder.defaultCollapsed(elements: elements)
                Task { await mutate { $0.collapsed = ids } }
            }
            toolbarButton("重新排布", systemImage: "arrow.triangle.branch", showsTitle: showsTitles) {
                Task {
                    await mutate { $0.childOrder = [:] }
                    reloadToken &+= 1
                }
            }
        }
        .fixedSize()
    }

    private var toolbarTrailing: some View {
        HStack(spacing: AppDesign.Spacing.xs) {
            Text("\(elements.nodes.count) 节点 · \(overlay.links.count) 链接")
                .font(AppDesign.Typography.micro.monospacedDigit())
                .foregroundStyle(.tertiary)
                .help("\(overlay.noteCards.count) 张笔记")
            HeaderIconButton(systemName: "viewfinder", help: "适应窗口") {
                fitRequest &+= 1
            }
        }
    }

    private func toolbarButton(
        _ title: String,
        systemImage: String,
        showsTitle: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(showsTitle ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
                .font(AppDesign.Typography.aux.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, showsTitle ? 8 : 6)
                .frame(height: AppDesign.Size.toolbarControl - 2)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    // MARK: - 行为

    /// 只有题目节点对应外部学习项。根节点和知识点节点留在脑图里复盘，
    /// 不再猜一个子节点代替跳转——那会让「打开」的结果不可预测。
    private func activate(nodeID: String) {
        guard let recordID = elements.nodes.first(where: { $0.id == nodeID })?.recordID else { return }
        workspace.selectedLearningRecordID = recordID
        workspace.selectedSection = .library
    }

    /// 补一份 AI 讲解。走的是和今日复习完全相同的那条链路，
    /// 结果存回学习记录，所以两边看到的是同一份，也不会为同一道题生成两次。
    private func generateLesson(nodeID: String, force: Bool) async {
        guard let recordID = elements.nodes.first(where: { $0.id == nodeID })?.recordID,
              let record = dataStore.learningRecords.first(where: { $0.id == recordID }),
              !busyNodes.contains(nodeID)
        else { return }
        busyNodes.insert(nodeID)
        errorText = ""
        defer { busyNodes.remove(nodeID) }
        do {
            try await LearningPackageProvisioner.ensurePackage(
                for: record,
                dataStore: dataStore,
                force: force
            )
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func createLink(source: String, target: String, directed: Bool) async {
        guard source != target else { return }
        let exists = overlay.links.contains {
            ($0.source == source && $0.target == target) || ($0.source == target && $0.target == source)
        }
        guard !exists else { return }
        await mutate { current in
            current.links.append(
                KnowledgeGraphOverlay.Link(
                    id: "link:\(UUID().uuidString)",
                    source: source,
                    target: target,
                    directed: directed
                )
            )
        }
        isLinking = false
    }

    private func load() async {
        let stored = await KnowledgeGraphStore.shared.overlay(dataDirectory: dataStore.dataDirectory)
        let live = Set(derived.nodes.map(\.id))
        let cleaned = stored.reconciled(liveIDs: live)
        if cleaned != stored {
            // 派生层变过（AI 改了知识路径、或者知识点被删了），把断链落盘清掉，
            // 而不是每次打开都重新过滤一遍。
            _ = await KnowledgeGraphStore.shared.update(dataDirectory: dataStore.dataDirectory) { current in
                current = current.reconciled(liveIDs: live)
            }
        }
        // 首次打开只留根与一级分支展开：几十个节点全铺开时，
        // 缩到能看全整棵树，字就已经小到读不了了。
        if !cleaned.didSeedCollapse {
            let seed = KnowledgeGraphBuilder.defaultCollapsed(elements: derived)
            overlay = await KnowledgeGraphStore.shared.update(dataDirectory: dataStore.dataDirectory) { current in
                current = current.reconciled(liveIDs: live)
                current.collapsed = seed
                current.didSeedCollapse = true
            }
        } else {
            overlay = cleaned
        }
        isLoaded = true
    }

    private func mutate(_ change: @escaping @Sendable (inout KnowledgeGraphOverlay) -> Void) async {
        let updated = await KnowledgeGraphStore.shared.update(
            dataDirectory: dataStore.dataDirectory,
            change
        )
        overlay = updated.reconciled(liveIDs: Set(derived.nodes.map(\.id)))
    }
}
