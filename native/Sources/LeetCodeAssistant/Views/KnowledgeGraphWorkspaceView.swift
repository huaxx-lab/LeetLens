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
            .task(id: dataStore.activeLearningRevision) { await load() }
            .onChange(of: workspace.selectedLearningRecordID) { _, value in
                // 从别的模块跳进来时，把镜头对到那道题上。
                guard let value, isLoaded else { return }
                let id = KnowledgeGraphBuilder.nodeID(forRecord: value)
                guard elements.nodes.contains(where: { $0.id == id }) else { return }
                selectedNodeID = id
                focusRequest = id
            }
    }

    // MARK: - 画布

    private var canvas: some View {
        // 工具栏占自己的一行，不再浮在画布上——浮着会压住最上面那几张卡片。
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .frame(height: 46)
                .background(.bar)
            Divider()
            graphCanvas
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
                .font(.system(size: 12))
                .lineLimit(2)
            Button {
                errorText = ""
            } label: {
                Image(systemName: "xmark").font(.system(size: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassCapsule()
        .padding(.bottom, 18)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索节点", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .frame(width: 130)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .glassCapsule()

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
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isLinking ? Color.accentColor : .secondary)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: isLinking ? 104 : 66, height: 30)
            .background(isLinking ? Color.accentColor.opacity(0.12) : .clear, in: Capsule())
            .glassCapsule()
            .help("连好后点虚线可以跳转或删除")

            // 展开 / 收起是大图能不能看的关键，放在最显眼的位置。
            HStack(spacing: 2) {
                toolbarButton("展开全部", systemImage: "arrow.up.left.and.arrow.down.right") {
                    Task { await mutate { $0.collapsed = [] } }
                }
                Divider().frame(height: 14)
                toolbarButton("只看主干", systemImage: "arrow.down.right.and.arrow.up.left") {
                    let ids = KnowledgeGraphBuilder.defaultCollapsed(elements: elements)
                    Task { await mutate { $0.collapsed = ids } }
                }
                Divider().frame(height: 14)
                toolbarButton("重新排布", systemImage: "arrow.triangle.branch") {
                    Task {
                        await mutate { $0.childOrder = [:] }
                        reloadToken &+= 1
                    }
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 30)
            .glassCapsule()

            Spacer(minLength: 8)

            Text("\(elements.nodes.count) 节点 · \(overlay.links.count) 链接 · \(overlay.noteCards.count) 笔记")
                .font(AppDesign.Typography.micro.monospacedDigit())
                .foregroundStyle(.secondary)

            Button { fitRequest &+= 1 } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassCircle()
            .help("适应窗口")
        }
    }

    private func toolbarButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
