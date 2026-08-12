import AppKit
import SwiftUI

/// 供应商标识。
///
/// 三个内置资源的画布并不一致——deepseek.png 是 64×64 的透明字形、alibaba-cloud.svg 是 32×32 的透明字形，
/// 而 opencode.svg 是 512×512 **满幅不透明**的 `#131010` 方块（透明像素 0%）。
/// 直接铺出来就是"两个小图标 + 一块黑砖"，视觉重量完全不统一。
/// 这里统一按 App 图标的口径处理：一律裁进连续圆角方块，满幅底色的自然变成圆角色块，
/// 透明字形则留出内边距，三者占据同样的光学面积。
struct ProviderMark: View {
    let assetName: String?
    var size: CGFloat = 22

    /// 满幅底色的资源不再额外内缩（它本身就要铺满圆角块），
    /// 透明字形按 12% 内缩，视觉大小才和前者一致。
    private var glyphInset: CGFloat { isFullBleed ? 0 : size * 0.12 }

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(glyphInset)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "cpu")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .clipped()
                .accessibilityHidden(true)
        }
    }

    /// 目前只有 OpenCode 的标识是满幅底色。写成白名单而不是逐帧扫描像素：
    /// 这个视图在模型菜单里会被渲染几十次，不能每次都去解码位图统计 alpha。
    private var isFullBleed: Bool { assetName == "opencode" }

    private var image: NSImage? {
        guard let assetName else { return nil }
        let extensions = ["png", "svg"]
        for fileExtension in extensions {
            let url = Bundle.module.url(forResource: assetName, withExtension: fileExtension)
                ?? Bundle.module.url(
                    forResource: assetName,
                    withExtension: fileExtension,
                    subdirectory: "Providers"
                )
            if let url, let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }
}

struct CompactIconButton: View {
    let title: String
    let systemImage: String
    var isSelected = false
    var badge = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: AppDesign.Size.toolbarControl, height: AppDesign.Size.toolbarControl)
                    .background(
                        isSelected ? Color.primary.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: AppDesign.Radius.small, style: .continuous)
                    )

                if badge {
                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(.background, lineWidth: 1))
                        .offset(x: 1, y: -1)
                }
            }
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
