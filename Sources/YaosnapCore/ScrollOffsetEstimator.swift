import CoreGraphics

public struct ScrollOffsetEstimate {
    /// 正数表示内容向下滚动（新内容从底部出现），与 ScrollStitcher 的约定一致。
    public let offsetPx: CGFloat
    public let confidence: Float
    /// 视口底部「固定不动」的条带高度（像素）：聊天输入框、播放条这类不随内容滚动的元素。
    /// 拼接时必须从追加条带里剔除，否则每帧都会把同一条固定 UI 拼进长图。
    public let stickyBottomPx: Int
    /// 视口顶部「固定不动」的条带高度：标题栏、工具栏。向上滚动前插时同样要剔除。
    public let stickyTopPx: Int

    public init(
        offsetPx: CGFloat,
        confidence: Float,
        stickyBottomPx: Int = 0,
        stickyTopPx: Int = 0
    ) {
        self.offsetPx = offsetPx
        self.confidence = confidence
        self.stickyBottomPx = stickyBottomPx
        self.stickyTopPx = stickyTopPx
    }
}

public protocol ScrollOffsetEstimating {
    func estimate(current: CGImage, previous: CGImage) -> ScrollOffsetEstimate?
    /// 断链重建用的大窗口估计：允许更大的位移，宁可用一次大范围搜索把长图接回去。
    /// 默认实现等同常规估计，测试替身不必关心这个区别。
    func estimateForReconnect(current: CGImage, previous: CGImage) -> ScrollOffsetEstimate?
}

public extension ScrollOffsetEstimating {
    func estimateForReconnect(current: CGImage, previous: CGImage) -> ScrollOffsetEstimate? {
        estimate(current: current, previous: previous)
    }
}

/// 滚动位移估计：行剖面互相关 + 分块一致性校验。
///
/// 为什么不用 Vision 配准：真实页面（深色底 + 正文文字）上 VNTranslationalImageRegistration
/// 频繁给出错误位移并附带 conf=1.0——同一组帧实测它报 -970，而画面真实位移是 -584；
/// 横带投票因此条条矛盾、整帧被丢弃，长图不再增长。改成纯 CPU 的行剖面搜索是确定性的，
/// 实测 1984×1488 帧约 10ms，比 Vision 更快也更稳。
///
/// 步骤：
/// 1. 两帧各自降采样成「24 列 × 原高」的灰度行剖面；
/// 2. 在 ±(1-最小重叠比例) 高度范围内逐一试位移，取平均绝对差最小的整数位移；
/// 3. 用 1/2 降采样的分块比较做一致性校验（容差 ±2 源像素，跳过固定不动的块）；
/// 4. 顺带测出底部固定条带高度，供拼接器剔除固定 UI。
public struct ScrollOffsetEstimator: ScrollOffsetEstimating {
    private let profileColumns = 24
    /// 两帧至少要保留的重叠比例。位移接近整帧时重叠区太小，任何位移都能凑出低代价，
    /// 实测会挑出 -1286 / +1293 这种极端值，所以常规路径限制在 60% 位移内；
    /// 断链后重建同步时才放宽到 85%，宁可用一次大窗口把长图接回去。
    private let minimumOverlapFraction: CGFloat
    /// 行剖面平均灰度差上限（0-255）。
    /// 实测真实正确匹配的代价在 0.04~0.24，错误匹配在 2.4 以上；
    /// 阈值放宽到 24 会把错误位移当成成功，这正是长图里出现重复段（同一段内容被拼两次）的原因。
    private let maximumMeanCost: CGFloat = 2.0
    /// 位移 0 的代价低于此值即判为静止画面，不再尝试其他位移。
    private let staticCostThreshold: CGFloat = 0.5
    /// 代价最小的前若干个候选逐个做分块校验，通过即采用。
    private let maximumCandidateAttempts = 12

    /// 校验用降采样倍数。取 4 曾把「位移不是 4 的整数倍」的合法帧误判为不匹配（相位错位），
    /// 取 2 时 ±1 个降采样像素已能覆盖取整误差。
    private let validationDownsampleScale = 2
    private let validationTileSize = 8
    private let tileMatchDifferenceThreshold: CGFloat = 8
    private let minimumTileActivityRange = 8
    private let minimumActiveTileCount = 4
    private let matchingTileFractionThreshold: CGFloat = 0.5
    /// 判定「固定条带」时允许的同位置灰度差。
    private let stickyRowTolerance: CGFloat = 2.5

    public init(minimumOverlapFraction: CGFloat = 0.40) {
        self.minimumOverlapFraction = minimumOverlapFraction
    }

    public func estimate(current: CGImage, previous: CGImage) -> ScrollOffsetEstimate? {
        estimate(current: current, previous: previous, overlapFraction: minimumOverlapFraction)
    }

    public func estimateForReconnect(current: CGImage, previous: CGImage) -> ScrollOffsetEstimate? {
        estimate(current: current, previous: previous, overlapFraction: 0.15)
    }

    private func estimate(
        current: CGImage,
        previous: CGImage,
        overlapFraction: CGFloat
    ) -> ScrollOffsetEstimate? {
        guard current.width == previous.width,
              current.height == previous.height,
              current.width > 0,
              current.height > 1 else { return nil }

        guard let currentProfile = rowProfile(current),
              let previousProfile = rowProfile(previous) else { return nil }

        let height = current.height
        let maximumShift = Int(CGFloat(height) * (1 - overlapFraction))
        guard maximumShift > 1 else { return nil }

        // 同位置几乎不变的行属于固定 UI（标题栏、输入框），不参与位移代价：
        // 参与的话会把真实位移的代价抬高到阈值之外（实测固定标题栏+滚动正文时曾直接判 nil）。
        let movingRows = movingRowMask(
            current: currentProfile, previous: previousProfile,
            columns: profileColumns, height: height
        )
        // 参与比较的行数下限：重叠区太小时任何位移都能凑出低代价，必须排除。
        let minimumComparedRows = max(8, height / 6)
        var candidates = shiftCandidates(
            current: currentProfile, previous: previousProfile,
            columns: profileColumns, height: height, maximumShift: maximumShift,
            rows: movingRows, minimumComparedRows: minimumComparedRows
        )
        guard !candidates.isEmpty else { return nil }

        // 分块校验用的降采样只算一次，供所有候选复用。
        let comparison = downsampled(current: current, previous: previous)

        let sticky = stickyBottomHeight(
            current: currentProfile, previous: previousProfile,
            columns: profileColumns, height: height
        )
        let stickyTop = stickyTopHeight(
            current: currentProfile, previous: previousProfile,
            columns: profileColumns, height: height
        )

        // 静止画面必须先判：纯色/静止时所有位移的代价并列接近 0，
        // 曾在并列中挑出 -1286 这种极端位移，被拼接器当成连续反向滚动，把长图裁到 1 像素。
        if let zero = candidates.first(where: { $0.shift == 0 }), zero.cost < staticCostThreshold {
            return ScrollOffsetEstimate(
                offsetPx: 0, confidence: 1, stickyBottomPx: sticky, stickyTopPx: stickyTop
            )
        }

        // 代价升序；代价同档（量化到 0.05）时优先更小位移，避免并列时选中极端值。
        candidates.sort { left, right in
            let leftBucket = Int((left.cost / 0.05).rounded())
            let rightBucket = Int((right.cost / 0.05).rounded())
            if leftBucket != rightBucket { return leftBucket < rightBucket }
            return abs(left.shift) < abs(right.shift)
        }

        // 逐个验证前几个候选：分块一致性校验才是真正的判别器。
        // 只看「最优代价是否明显优于次优」在文字密集页面上会大面积误杀（实测 cost 9.45 vs 9.47）。
        for candidate in candidates.prefix(maximumCandidateAttempts) {
            guard candidate.cost <= maximumMeanCost else { break }
            guard matches(comparison, offsetPx: CGFloat(candidate.shift), sourceHeight: height) else {
                continue
            }
            return ScrollOffsetEstimate(
                offsetPx: CGFloat(candidate.shift),
                confidence: Float(max(0, 1 - candidate.cost / maximumMeanCost)),
                stickyBottomPx: sticky,
                stickyTopPx: stickyTop
            )
        }
        return nil
    }

    // MARK: - 行剖面

    /// 把图像降采样成 columns 列灰度的行剖面，返回 height × columns 的扁平数组。
    private func rowProfile(_ image: CGImage) -> [Float]? {
        let columns = profileColumns
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: columns,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: columns * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: height))
        guard let base = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var profile = [Float](repeating: 0, count: height * columns)
        for y in 0..<height {
            let rowBase = y * columns * 4
            let outBase = y * columns
            for column in 0..<columns {
                let index = rowBase + column * 4
                profile[outBase + column] = Float(base[index]) * 0.299
                    + Float(base[index + 1]) * 0.587
                    + Float(base[index + 2]) * 0.114
            }
        }
        return profile
    }

    /// 逐行标记「是否参与位移估计」。整帧都判成静止时退回全帧（画面确实没动）。
    private func movingRowMask(
        current: [Float],
        previous: [Float],
        columns: Int,
        height: Int
    ) -> [Bool] {
        var mask = [Bool](repeating: false, count: height)
        var movingCount = 0
        for y in 0..<height {
            let rowBase = y * columns
            var rowDifference: Float = 0
            for column in 0..<columns {
                rowDifference += abs(current[rowBase + column] - previous[rowBase + column])
            }
            let moving = CGFloat(rowDifference) / CGFloat(columns) > stickyRowTolerance
            mask[y] = moving
            if moving { movingCount += 1 }
        }
        guard movingCount >= max(8, height / 20) else {
            return [Bool](repeating: true, count: height)
        }
        return mask
    }

    /// 全区间位移搜索。
    ///
    /// 曾经试过「行 4:1 抽稀粗搜 + 细化」，但抽稀后的剖面在深色正文画面上几乎失去结构，
    /// 粗搜排名不可靠，反而把真实位移挡在细化窗口之外（实测 8 对真实帧全部返回 nil）。
    /// 实测全分辨率全区间扫描在 2364×1318 帧上只有约 10ms，没有必要为它牺牲正确性。
    private func shiftCandidates(
        current: [Float],
        previous: [Float],
        columns: Int,
        height: Int,
        maximumShift: Int,
        rows movingRows: [Bool],
        minimumComparedRows: Int
    ) -> [(shift: Int, cost: CGFloat)] {
        var shifts: [Int] = []
        shifts.reserveCapacity(2 * maximumShift + 1)
        for shift in -maximumShift...maximumShift {
            shifts.append(shift)
        }
        return fullScan(
            current: current, previous: previous, columns: columns, height: height,
            shifts: shifts, rows: movingRows, minimumComparedRows: minimumComparedRows
        )
    }

    /// 对给定位移集合计算平均灰度差；参与比较的行数不足者丢弃。
    private func fullScan(
        current: [Float],
        previous: [Float],
        columns: Int,
        height: Int,
        shifts: [Int],
        rows movingRows: [Bool],
        minimumComparedRows: Int
    ) -> [(shift: Int, cost: CGFloat)] {
        var results: [(shift: Int, cost: CGFloat)] = []
        results.reserveCapacity(shifts.count)
        for shift in shifts {
            let start = max(0, -shift)
            let end = min(height, height - shift)
            guard end - start > 4 else { continue }
            var total: CGFloat = 0
            var compared = 0
            for y in start..<end where movingRows[y] {
                let currentRow = y * columns
                let previousRow = (y + shift) * columns
                var rowTotal: Float = 0
                for column in 0..<columns {
                    rowTotal += abs(current[currentRow + column] - previous[previousRow + column])
                }
                total += CGFloat(rowTotal) / CGFloat(columns)
                compared += 1
            }
            guard compared >= minimumComparedRows else { continue }
            results.append((shift, total / CGFloat(compared)))
        }
        return results
    }

    // MARK: - 固定条带

    /// 从画面底部往上数，统计「与上一帧同位置像素几乎一致」的连续行数。
    /// 这些行不随内容滚动（输入框、工具条），拼接时要剔除。
    private func stickyBottomHeight(
        current: [Float],
        previous: [Float],
        columns: Int,
        height: Int
    ) -> Int {
        guard height > 32 else { return 0 }
        let limit = height / 3
        var sticky = 0
        var y = height - 1
        while sticky < limit {
            let rowBase = y * columns
            var rowDifference: Float = 0
            for column in 0..<columns {
                rowDifference += abs(current[rowBase + column] - previous[rowBase + column])
            }
            let mean = CGFloat(rowDifference) / CGFloat(columns)
            guard mean <= stickyRowTolerance else { break }
            sticky += 1
            y -= 1
            if y < 0 { break }
        }
        return sticky
    }

    /// 从画面顶部往下数，统计「与上一帧同位置几乎一致」的连续行数（固定标题栏/工具条）。
    private func stickyTopHeight(
        current: [Float],
        previous: [Float],
        columns: Int,
        height: Int
    ) -> Int {
        guard height > 32 else { return 0 }
        let limit = height / 3
        var sticky = 0
        var y = 0
        while sticky < limit {
            let rowBase = y * columns
            var rowDifference: Float = 0
            for column in 0..<columns {
                rowDifference += abs(current[rowBase + column] - previous[rowBase + column])
            }
            let mean = CGFloat(rowDifference) / CGFloat(columns)
            guard mean <= stickyRowTolerance else { break }
            sticky += 1
            y += 1
            if y >= height { break }
        }
        return sticky
    }

    // MARK: - 分块一致性校验

    private struct Downsampled {
        let current: [UInt8]
        let previous: [UInt8]
        let width: Int
        let height: Int
    }

    private func matches(_ downsample: Downsampled?, offsetPx: CGFloat, sourceHeight: Int) -> Bool {
        guard let downsample else { return false }
        let scale = CGFloat(sourceHeight) / CGFloat(downsample.height)
        let shift = (offsetPx / scale).rounded()
        // 降采样取整会带来 ±1 降采样像素（≈ ±2 源像素）误差，三个候选都要试。
        for candidate in [shift, shift - 1, shift + 1] {
            if matches(downsample, shift: Int(candidate)) { return true }
        }
        return false
    }

    private func downsampled(current: CGImage, previous: CGImage) -> Downsampled? {
        let width = max(1, current.width / validationDownsampleScale)
        let height = max(1, current.height / validationDownsampleScale)
        guard let currentPixels = grayPixels(current, width: width, height: height),
              let previousPixels = grayPixels(previous, width: width, height: height) else { return nil }
        return Downsampled(current: currentPixels, previous: previousPixels, width: width, height: height)
    }

    private func grayPixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return Array(UnsafeBufferPointer(start: base, count: width * height))
    }

    private func matches(_ downsample: Downsampled, shift: Int) -> Bool {
        let width = downsample.width
        let height = downsample.height
        let startRow = max(0, -shift)
        let endRow = min(height, height - shift)
        guard endRow - startRow >= validationTileSize else { return false }

        var activeTiles = 0
        var matchedTiles = 0
        var row = startRow
        while row + validationTileSize <= endRow {
            var column = 0
            while column + validationTileSize <= width {
                var difference = 0
                var samples = 0
                var minimum = 255
                var maximum = 0
                var staticDifference = 0
                for tileRow in row..<(row + validationTileSize) {
                    let currentBase = tileRow * width
                    let previousBase = (tileRow + shift) * width
                    for tileColumn in column..<(column + validationTileSize) {
                        let currentValue = Int(downsample.current[currentBase + tileColumn])
                        let previousValue = Int(downsample.previous[previousBase + tileColumn])
                        difference += abs(currentValue - previousValue)
                        samples += 1
                        minimum = min(minimum, currentValue)
                        maximum = max(maximum, currentValue)
                        staticDifference += abs(
                            currentValue - Int(downsample.previous[currentBase + tileColumn])
                        )
                    }
                }
                // 固定 UI 的块（同位置不动）不参与统计，避免整块拉低匹配率。
                let isStatic = CGFloat(staticDifference) / CGFloat(max(samples, 1)) <= 2
                if maximum - minimum >= minimumTileActivityRange && !isStatic {
                    activeTiles += 1
                    if CGFloat(difference) / CGFloat(max(samples, 1)) <= tileMatchDifferenceThreshold {
                        matchedTiles += 1
                    }
                }
                column += validationTileSize
            }
            row += validationTileSize
        }

        guard activeTiles >= minimumActiveTileCount else { return false }
        return CGFloat(matchedTiles) / CGFloat(activeTiles) >= matchingTileFractionThreshold
    }
}