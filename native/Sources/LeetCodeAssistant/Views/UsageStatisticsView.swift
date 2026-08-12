import SwiftUI

struct UsageStatisticsView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore
    @State private var scope = Scope.current
    @State private var ledger = AIUsageSnapshot.empty
    @Environment(\.dismiss) private var dismiss

    private enum Scope: Hashable {
        case current
        case all
    }

    private var usage: ConversationUsage {
        let legacy: ConversationUsage
        let intercepted: ConversationUsage
        switch scope {
        case .current:
            guard let id = workspace.selectedConversationID else { return ConversationUsage() }
            legacy = dataStore.conversations.first { $0.id == id }?.usage ?? ConversationUsage()
            intercepted = ledger.byConversation[id]?.conversationUsage ?? ConversationUsage()
        case .all:
            legacy = dataStore.conversations.reduce(ConversationUsage()) { $0 + $1.usage }
            intercepted = ledger.totals.conversationUsage
        }
        return legacy + intercepted
    }

    private var requestCounters: AIUsageCounters {
        switch scope {
        case .current:
            guard let id = workspace.selectedConversationID else { return AIUsageCounters() }
            return ledger.byConversation[id] ?? AIUsageCounters()
        case .all:
            return ledger.totals
        }
    }

    private var taskRows: [(AITaskRoute, AIUsageCounters)] {
        AITaskRoute.allCases.compactMap { route in
            guard let counters = ledger.byTask[route.rawValue], counters.requestCount > 0 else { return nil }
            return (route, counters)
        }
    }

    private var providerRows: [(String, AIUsageCounters)] {
        ledger.byProvider
            .filter { !$0.key.isEmpty && $0.value.requestCount > 0 }
            .sorted { $0.value.totalTokens > $1.value.totalTokens }
    }

    private var modelRows: [(providerID: String, model: String, counters: AIUsageCounters)] {
        ledger.byModel.compactMap { key, counters in
            guard counters.requestCount > 0,
                  let separator = key.firstIndex(of: "\u{1F}")
            else { return nil }
            return (
                String(key[..<separator]),
                String(key[key.index(after: separator)...]),
                counters
            )
        }
        .sorted { $0.counters.totalTokens > $1.counters.totalTokens }
    }

    private var cacheRate: Double? {
        guard usage.cacheSupported, usage.cacheTrackedPromptTokens > 0 else { return nil }
        return min(1, Double(usage.cachedTokens) / Double(usage.cacheTrackedPromptTokens))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 用量统计").font(.title2.weight(.semibold))
                    Text("所有模型调用统一计入，不依赖对话记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 12) {
                        GlassSegmentedControl(
                            options: [("current", "当前对话"), ("all", "全部 AI 调用")],
                            selection: Binding(
                                get: { scope == .current ? "current" : "all" },
                                set: { scope = $0 == "current" ? .current : .all }
                            )
                        )
                        .frame(width: 260)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(usage.estimatedRequests > 0 ? "含 \(usage.estimatedRequests) 次中断估算" : "精确统计")
                                .font(.caption2)
                                .foregroundStyle(usage.estimatedRequests > 0 ? Color.orange : .secondary)
                            Text(usage.model.isEmpty ? "尚未请求" : usage.model)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                        }
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                        metricCard("输入 Token", usage.promptTokens, icon: "arrow.down.circle", tint: .blue)
                        metricCard("输出 Token", usage.completionTokens, icon: "arrow.up.circle", tint: .indigo)
                        metricCard("总计", usage.totalTokens, icon: "sum", tint: .purple)
                        metricCard("缓存 Token", usage.cacheSupported ? usage.cachedTokens : nil, icon: "bolt.horizontal.circle", tint: .teal)
                        metricCard("推理 Token", usage.reasoningTokens, icon: "brain", tint: .pink)
                        metricCard("工具调用", usage.toolCalls, icon: "wrench.and.screwdriver", tint: .orange)
                    }

                    HStack(spacing: 10) {
                        requestChip("成功", requestCounters.succeededRequests, color: .green)
                        requestChip("失败", requestCounters.failedRequests, color: .red)
                        requestChip("已取消", requestCounters.cancelledRequests, color: .gray)
                        requestChip("总请求", requestCounters.requestCount, color: .blue)
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("累计缓存命中率", systemImage: "bolt.horizontal.circle.fill")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.teal)
                            Spacer()
                            Text(cacheRate?.formatted(.percent.precision(.fractionLength(1))) ?? "-")
                                .font(.headline.monospacedDigit())
                        }
                        ProgressView(value: cacheRate ?? 0)
                            .tint(.teal)
                        Text(cacheRate == nil ? "服务端返回缓存明细后显示" : "实际命中 \(usage.cachedTokens.formatted()) / \(usage.cacheTrackedPromptTokens.formatted()) 个可统计输入 Token")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(Color.teal.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.teal.opacity(0.12))
                    }

                    if scope == .all, !providerRows.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("供应商与模型")
                                .font(.subheadline.weight(.semibold))
                            ForEach(providerRows, id: \.0) { providerID, counters in
                                usageBreakdownRow(
                                    title: dataStore.providers.first { $0.id == providerID }?.name ?? providerID,
                                    subtitle: "供应商 · \(counters.requestCount) 次请求",
                                    counters: counters,
                                    systemImage: "server.rack"
                                )
                            }
                            ForEach(Array(modelRows.prefix(8).enumerated()), id: \.offset) { _, row in
                                usageBreakdownRow(
                                    title: row.model,
                                    subtitle: "模型 · \(dataStore.providers.first { $0.id == row.providerID }?.name ?? row.providerID)",
                                    counters: row.counters,
                                    systemImage: "cpu"
                                )
                            }
                        }
                    }

                    if scope == .all, !taskRows.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("调用来源")
                                .font(.subheadline.weight(.semibold))
                            ForEach(taskRows, id: \.0.id) { route, counters in
                                HStack(spacing: 12) {
                                    Image(systemName: route.systemImage)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.blue)
                                        .frame(width: 30, height: 30)
                                        .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(route.title).font(.subheadline.weight(.medium))
                                        Text(route.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text("\(counters.requestCount) 次")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\(counters.totalTokens.formatted()) Token")
                                        .font(.callout.weight(.medium).monospacedDigit())
                                        .frame(width: 118, alignment: .trailing)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                    }
                }
                .padding(28)
            }
            .floatingScrollIndicators()
        }
        .frame(width: 760, height: scope == .all && !taskRows.isEmpty ? 700 : 620)
        .task { await refreshLedger() }
        .onReceive(NotificationCenter.default.publisher(for: .aiUsageLedgerDidChange)) { notification in
            guard notification.object as? String == dataStore.dataDirectory.standardizedFileURL.path else { return }
            Task { await refreshLedger() }
        }
    }

    private func metricCard(_ title: String, _ value: Int?, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(value?.formatted() ?? "-")
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.12))
        }
    }

    private func usageBreakdownRow(
        title: String,
        subtitle: String,
        counters: AIUsageCounters,
        systemImage: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.indigo)
                .frame(width: 30, height: 30)
                .background(Color.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text("\(counters.totalTokens.formatted()) Token")
                .font(.callout.weight(.medium).monospacedDigit())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func requestChip(_ title: String, _ value: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).foregroundStyle(.secondary)
            Text(value.formatted()).fontWeight(.semibold).monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.08), in: Capsule())
    }

    @MainActor
    private func refreshLedger() async {
        ledger = await AIUsageLedger.shared.snapshot(dataDirectory: dataStore.dataDirectory)
    }
}
