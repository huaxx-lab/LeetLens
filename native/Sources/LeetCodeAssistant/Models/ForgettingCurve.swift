import Foundation

/// 遗忘曲线。
///
/// 排期本来就跑在 FSRS 上（`learning-engine.cjs` 里的 ts-fsrs），但原生这一侧只读到了
/// 「下次该复习的时间」，没读到「现在还记得多少」——于是掌握度是一个从上次做题起就冻住的数字，
/// 三个月没碰的题和昨天刚练过的题看起来一样熟。
///
/// 这里把同一条曲线搬到 Swift：
///
///     R(t) = (1 + FACTOR · t / S) ^ DECAY
///
/// 参数和引擎里那份 ts-fsrs（v5.4.1 / FSRS-6）的默认值保持一致，
/// 所以两边算出来的保持率是同一个数，不会出现「今日复习说该练了、熟练度说还很熟」。
enum ForgettingCurve {
    /// FSRS-6 默认 decay（引擎里是 w[20] = 0.1542，公式取负）。
    static let decay = -0.1542
    /// factor = exp(ln(0.9) / decay) − 1，让 t = S 时 R 正好落在 0.9。
    static let factor = Foundation.exp(Foundation.log(0.9) / decay) - 1

    /// 目标保持率。低于它就该复习了——引擎的 `request_retention` 也是这个数。
    static let requestRetention = 0.9

    /// 距上次复习 `elapsedDays` 天之后还能想起来的概率。
    ///
    /// 没有稳定度或者从没复习过就返回 nil：这时候没有曲线可言，
    /// 硬凑一个数只会给排序添一条假信号。
    static func retention(stability: Double, elapsedDays: Double) -> Double? {
        guard stability > 0, stability.isFinite, elapsedDays.isFinite else { return nil }
        let days = max(0, elapsedDays)
        let value = Foundation.pow(1 + factor * days / stability, decay)
        guard value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    /// 掌握度按遗忘打个折：「学过」和「现在还会」不是一回事。
    ///
    /// 折扣公式与 `learning-engine.cjs` 的 `viewItem` 完全相同，
    /// 两个引擎必须给出同一个百分比，否则同一道题在不同页面上是两个数。
    static func effectiveScore(_ score: Double, retention: Double?) -> Double {
        let base = min(max(score, 0), 100)
        guard let retention else { return base }
        let penalty = max(0, requestRetention - retention) * 24
        return min(max(base - penalty, 0), 100)
    }

    /// 还有几天掉到目标保持率。负数表示已经掉下去了（该复习而没复习）。
    static func daysUntil(
        retention target: Double,
        stability: Double,
        elapsedDays: Double
    ) -> Double? {
        guard stability > 0, stability.isFinite, target > 0, target < 1 else { return nil }
        let horizon = stability * (Foundation.pow(target, 1 / decay) - 1) / factor
        guard horizon.isFinite else { return nil }
        return horizon - elapsedDays
    }
}
