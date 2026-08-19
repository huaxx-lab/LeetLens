import CoreGraphics

/// Pinned widths for the SwiftUI workspace columns.
/// The shell is `NavigationSplitView` + `.inspector`; these numbers are the
/// contract those modifiers must honor, not an AppKit split-view implementation.
enum WorkspaceSplitLayoutPolicy {
    static var sidebarMin: CGFloat { AppDesign.Size.sidebarMin }
    static var sidebarIdeal: CGFloat { AppDesign.Size.sidebarIdeal }
    static var sidebarMax: CGFloat { AppDesign.Size.sidebarMax }
    static var detailMin: CGFloat { AppDesign.Size.primaryMinimum }
    static var inspectorMin: CGFloat { AppDesign.Size.inspectorMin }
    static var inspectorIdeal: CGFloat { AppDesign.Size.inspectorIdeal }
    static var inspectorMax: CGFloat { AppDesign.Size.inspectorMax }

    static var threeColumnMinimum: CGFloat { sidebarMin + detailMin + inspectorMin }

    static let sidebarHoldingPriority: Float = 270
    static let inspectorHoldingPriority: Float = 260
    static let detailHoldingPriority: Float = 1

    static func clampInspectorWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, inspectorMin), inspectorMax)
    }

    static func sidebarDividerLimit(proposed: CGFloat) -> CGFloat {
        min(max(proposed, sidebarMin), sidebarMax)
    }

    /// 三列的实际宽度。第三列放大时中间列宽度归零——但列本身不卸载，
    /// 由 `WorkspaceColumnShell` 裁掉，这样还原时会话页面不用重新加载。
    static func columnWidths(
        total: CGFloat,
        sidebarVisible: Bool,
        sidebarWidth: CGFloat,
        inspectorVisible: Bool,
        inspectorExpanded: Bool,
        inspectorWidth: CGFloat
    ) -> WorkspaceColumnWidths {
        guard total > 0 else { return WorkspaceColumnWidths(sidebar: 0, detail: 0, inspector: 0) }
        let sidebar = sidebarVisible ? min(max(sidebarWidth, 0), total) : 0
        let remaining = max(total - sidebar, 0)
        let inspector: CGFloat = {
            guard inspectorVisible else { return 0 }
            return inspectorExpanded ? remaining : min(max(inspectorWidth, 0), remaining)
        }()
        return WorkspaceColumnWidths(
            sidebar: sidebar,
            detail: max(remaining - inspector, 0),
            inspector: inspector
        )
    }

    static func inspectorDividerPosition(
        splitWidth: CGFloat,
        proposed: CGFloat,
        dividerThickness: CGFloat
    ) -> CGFloat {
        let minPosition = splitWidth - inspectorMax - dividerThickness
        let maxPosition = splitWidth - inspectorMin - dividerThickness
        return min(max(proposed, minPosition), maxPosition)
    }
}
