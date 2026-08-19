import SwiftUI

enum ContextPanelSizingPolicy {
    static let maximumHeight: CGFloat = 420

    private static let sectionHeaderHeight: CGFloat = 37
    private static let rowHeight: CGFloat = 45
    private static let sectionFooterHeight: CGFloat = 8
    private static let disclosureHeight: CGFloat = 37
    private static let dividerHeight: CGFloat = 1

    static func height(
        outputCount: Int,
        sourceCount: Int,
        expandedOutputCount: Int
    ) -> CGFloat {
        let visibleOutputCount = expandedOutputCount > 0
            ? min(outputCount, expandedOutputCount)
            : min(outputCount, 3)
        let visibleSourceCount = min(sourceCount, 3)

        func sectionHeight(totalCount: Int, visibleCount: Int) -> CGFloat {
            guard totalCount > 0 else { return 0 }
            return sectionHeaderHeight
                + (CGFloat(visibleCount) * rowHeight)
                + (totalCount > 3 ? disclosureHeight : 0)
                + sectionFooterHeight
        }

        let divider = outputCount > 0 && sourceCount > 0 ? dividerHeight : 0
        return min(
            maximumHeight,
            sectionHeight(totalCount: outputCount, visibleCount: visibleOutputCount)
                + divider
                + sectionHeight(totalCount: sourceCount, visibleCount: visibleSourceCount)
        )
    }
}

struct ContextPanelView: View {
    @Bindable var workspace: WorkspaceState
    let outputs: [ContextItem]
    let sources: [ContextItem]
    @State private var hoveredItemID: String?
    @State private var expandedSections: Set<String> = []
    /// 内容实测高度；首帧还没量到时退回 `ContextPanelSizingPolicy` 的估值。
    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !outputs.isEmpty {
                    contextSection("输出", items: outputs)
                }
                if !outputs.isEmpty && !sources.isEmpty {
                    Divider().padding(.horizontal, 14)
                }
                if !sources.isEmpty {
                    contextSection("来源", items: sources)
                }
            }
            // 面板高度按实测内容走：`ContextPanelSizingPolicy` 那套行高常量
            // 只能算个估值，差几点就会让内容"明明放得下"却还多出一条滚动条。
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .floatingScrollIndicators()
        .frame(height: preferredHeight)
        .navigationGlass(cornerRadius: AppDesign.Radius.floating, interactive: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("任务上下文")
    }

    private var preferredHeight: CGFloat {
        let estimate = ContextPanelSizingPolicy.height(
            outputCount: outputs.count,
            sourceCount: sources.count,
            expandedOutputCount: expandedSections.contains("输出") ? outputs.count : 0
        )
        guard let contentHeight, contentHeight > 0 else { return estimate }
        return min(ContextPanelSizingPolicy.maximumHeight, contentHeight)
    }

    private func contextSection(_ title: String, items: [ContextItem]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(AppDesign.Typography.bodyEmphasis)
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppDesign.Spacing.rowInset)
                .padding(.top, AppDesign.Spacing.sm)
                .padding(.bottom, AppDesign.Spacing.xxs)

            ForEach(Array((expandedSections.contains(title) ? items[...] : items.prefix(3)))) { item in
                contextRow(item)
            }

            if items.count > 3 {
                Button {
                    if title == "来源" {
                        workspace.presentSources(items)
                    } else {
                        withAnimation(AppDesign.Motion.selection) {
                            if expandedSections.contains(title) {
                                expandedSections.remove(title)
                            } else {
                                expandedSections.insert(title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: title == "来源" ? "sidebar.right" : (expandedSections.contains(title) ? "chevron.up" : "chevron.down"))
                        Text(title == "来源" ? "在右栏查看全部" : (expandedSections.contains(title) ? "收起" : "查看全部"))
                        Spacer(minLength: 0)
                        Text("\(items.count)")
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .font(AppDesign.Typography.aux)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppDesign.Spacing.rowInset)
            }
        }
        .padding(.bottom, 8)
        .onChange(of: items) { _, updated in
            if title == "来源", workspace.openToolTabs.contains(.sources) {
                workspace.presentedSources = updated
            }
        }
    }

    private func contextRow(_ item: ContextItem) -> some View {
        Button {
            withAnimation(AppDesign.Motion.panel) {
                workspace.openContextItem(item)
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.systemImage)
                    .font(AppDesign.Typography.icon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: AppDesign.Size.iconSlot, height: AppDesign.Size.iconSlot)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(AppDesign.Typography.bodyEmphasis)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(AppDesign.Typography.aux)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                if item.tool != nil || item.url != nil {
                    Image(systemName: "chevron.right")
                        .font(AppDesign.Typography.micro)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, AppDesign.Spacing.rowInset)
            .frame(maxWidth: .infinity, minHeight: 45, alignment: .leading)
            .background(
                hoveredItemID == item.id ? AppDesign.ColorToken.hover : .clear,
                in: RoundedRectangle(cornerRadius: AppDesign.Radius.small, style: .continuous)
            )
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(AppDesign.Motion.subtle) {
                hoveredItemID = hovering ? item.id : nil
            }
        }
        .accessibilityHint(item.url == nil ? "在工具工作区中打开" : "打开原始资源")
    }
}
