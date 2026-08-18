import Foundation
import Testing
@testable import LeetCodeAssistant

@Suite("悬浮滚动条几何")
struct FloatingScrollIndicatorTests {
    @Test("内容不超出视口时不画 thumb")
    func noThumbWithoutOverflow() {
        #expect(FloatingScrollIndicator.bar(offset: 0, contentLength: 400, containerLength: 400) == nil)
        #expect(FloatingScrollIndicator.bar(offset: 0, contentLength: 200, containerLength: 400) == nil)
        #expect(FloatingScrollIndicator.bar(offset: 0, contentLength: 800, containerLength: 0) == nil)
    }

    @Test("thumb 长度与内容成反比，且不短于下限")
    func thumbLengthTracksContent() {
        let short = FloatingScrollIndicator.bar(offset: 0, contentLength: 1000, containerLength: 500)
        let long = FloatingScrollIndicator.bar(offset: 0, contentLength: 5000, containerLength: 500)

        #expect(short != nil)
        #expect(long != nil)
        #expect(short!.length > long!.length)
        // 内容再长，thumb 也要留得住，不能细成一条看不见的线。
        let extreme = FloatingScrollIndicator.bar(offset: 0, contentLength: 500_000, containerLength: 500)
        #expect(extreme!.length == FloatingScrollIndicator.minimumLength)
    }

    @Test("滚到两端时 thumb 贴住轨道两头")
    func thumbReachesBothEnds() {
        let container: CGFloat = 500
        let content: CGFloat = 1500
        let top = FloatingScrollIndicator.bar(offset: 0, contentLength: content, containerLength: container)!
        let bottom = FloatingScrollIndicator.bar(offset: content - container, contentLength: content, containerLength: container)!
        let track = container - FloatingScrollIndicator.trackInset * 2

        #expect(top.origin == FloatingScrollIndicator.trackInset)
        #expect(bottom.origin + bottom.length == FloatingScrollIndicator.trackInset + track)
    }

    @Test("越界偏移被夹住，不会把 thumb 甩出轨道")
    func clampsRubberBandOffsets() {
        let container: CGFloat = 500
        let content: CGFloat = 1500
        // 橡皮筋回弹时 contentOffset 会是负数或超过最大值。
        let overscrollTop = FloatingScrollIndicator.bar(offset: -120, contentLength: content, containerLength: container)!
        let overscrollBottom = FloatingScrollIndicator.bar(offset: content, contentLength: content, containerLength: container)!
        let track = container - FloatingScrollIndicator.trackInset * 2

        #expect(overscrollTop.origin == FloatingScrollIndicator.trackInset)
        #expect(overscrollBottom.origin + overscrollBottom.length <= FloatingScrollIndicator.trackInset + track + 0.001)
    }

    @Test("视口太矮时宁可不画")
    func skipsUnusablyShortTracks() {
        #expect(FloatingScrollIndicator.bar(offset: 0, contentLength: 400, containerLength: 30) == nil)
    }

    /// 拖动的换算必须和 `bar` 用同一套 thumb 长度：thumb 走完整条轨道，
    /// 内容就要正好走完可滚区间，不多不少。
    @Test("thumb 拖到底就是内容的底")
    func dragMapsTrackTravelToContent() {
        let container: CGFloat = 500
        let content: CGFloat = 1500
        let track = container - FloatingScrollIndicator.trackInset * 2
        let length = FloatingScrollIndicator.bar(offset: 0, contentLength: content, containerLength: container)!.length

        let bottom = FloatingScrollIndicator.dragTarget(
            start: 0,
            translation: track - length,
            contentLength: content,
            containerLength: container
        )
        #expect(bottom == content - container)

        let half = FloatingScrollIndicator.dragTarget(
            start: 0,
            translation: (track - length) / 2,
            contentLength: content,
            containerLength: container
        )!
        #expect(abs(half - (content - container) / 2) < 0.001)
    }

    @Test("往回拖过头夹在两端，不会滚出内容")
    func dragClampsToBounds() {
        let target = FloatingScrollIndicator.dragTarget(
            start: 200,
            translation: -5_000,
            contentLength: 1500,
            containerLength: 500
        )
        #expect(target == 0)
        #expect(
            FloatingScrollIndicator.dragTarget(start: 200, translation: 5_000, contentLength: 1500, containerLength: 500)
                == 1_000
        )
    }

    @Test("画不出 thumb 的场合也不该产生拖动目标")
    func dragMatchesBarAvailability() {
        #expect(FloatingScrollIndicator.dragTarget(start: 0, translation: 20, contentLength: 400, containerLength: 400) == nil)
        #expect(FloatingScrollIndicator.dragTarget(start: 0, translation: 20, contentLength: 400, containerLength: 30) == nil)
    }
}
