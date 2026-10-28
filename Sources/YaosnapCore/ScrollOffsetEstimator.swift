import CoreGraphics
import Vision

public struct ScrollOffsetEstimate {
    /// 正数表示内容向下滚动（新内容从底部出现），与 ScrollStitcher 的约定一致。
    public let offsetPx: CGFloat
    public let confidence: Float

    public init(offsetPx: CGFloat, confidence: Float) {
        self.offsetPx = offsetPx
        self.confidence = confidence
    }
}

public protocol ScrollOffsetEstimating {
    func estimate(current: CGImage, previous: CGImage) -> ScrollOffsetEstimate?
}

/// 参考 ScrollSnap（MIT, Berker Gungor）的带状投票思路重写：
/// 多条横带各自配准，取一致组；全部不一致时退回全帧配准。
public struct VisionScrollOffsetEstimator: ScrollOffsetEstimating {
    private let comparisonBandCount = 5
    private let minimumComparisonBandHeight = 80
    private let agreementTolerance: CGFloat = 3
    private let maximumHorizontalMovement: CGFloat = 3
    private let minimumOverlapFraction: CGFloat = 0.15
    private let minimumConsensusCount = 4

    /// 校验用降采样倍数：缩到 1/4 宽高后像素数仅 1/16，6K 帧也不再产生数百 MB 临时缓冲。
    private let validationDownsampleScale = 4
    /// 降采样图上的块尺寸；16×16 降采样块约等于原图 64×64 区域，足以体现局部内容。
    private let validationTileSize = 16
    /// 匹配块的 RGB 三通道平均绝对差上限（0–255）。相同内容实测接近 0，无关噪声约 85。
    private let tileMatchDifferenceThreshold: CGFloat = 6
    /// 块内 RGB 动态范围下限。纯色块没有鉴别力，不计入统计，避免黑底/空白稀释差异。
    private let minimumTileActivityRange = 8
    /// 有鉴别力的块少于该数量时无法判断，保守返回不一致。
    private let minimumActiveTileCount = 4
    /// 匹配块占比下限。固定标题栏/工具栏只占少数块，不会拖累合法滚动帧。
    private let matchingTileFractionThreshold: CGFloat = 0.6

    public init() {}

    public func estimate(current: CGImage, previous: CGImage) -> ScrollOffsetEstimate? {
        guard current.width == previous.width,
              current.height == previous.height,
              current.width > 0,
              current.height > 0 else { return nil }

        let frameHeight = CGFloat(current.height)
        let bands = comparisonBands(width: current.width, height: current.height)
        // 两帧只在降采样后转换一次，供共识与全帧回退两条路径复用。
        let comparison = downsampledComparison(current: current, previous: previous)

        var bandOffsets: [CGFloat] = []
        for band in bands {
            guard let currentBand = current.cropping(to: band),
                  let previousBand = previous.cropping(to: band),
                  let translation = translation(from: currentBand, to: previousBand) else { continue }
            guard abs(translation.x) <= maximumHorizontalMovement,
                  abs(translation.y) <= frameHeight * (1 - minimumOverlapFraction) else { continue }
            bandOffsets.append(translation.y)
        }

        if let consensus = consensusOffset(in: bandOffsets, minimumCount: minimumConsensusCount),
           let comparison,
           hasMatchingContent(comparison, offsetPx: consensus.offsetPx, sourceHeight: current.height) {
            return consensus
        }

        guard let full = translation(from: current, to: previous),
              abs(full.y) <= frameHeight * (1 - minimumOverlapFraction),
              let comparison,
              hasMatchingContent(comparison, offsetPx: full.y, sourceHeight: current.height) else { return nil }
        return ScrollOffsetEstimate(offsetPx: full.y, confidence: full.confidence)
    }

    private func comparisonBands(width: Int, height: Int) -> [CGRect] {
        let bandHeight = min(height, max(minimumComparisonBandHeight, height / 3))
        let maxOriginY = max(0, height - bandHeight)
        guard maxOriginY > 0 else {
            return [CGRect(x: 0, y: 0, width: width, height: bandHeight)]
        }
        let origins = (0..<comparisonBandCount).map { index in
            Int((CGFloat(maxOriginY) * CGFloat(index) / CGFloat(comparisonBandCount - 1)).rounded())
        }
        return Array(Set(origins)).sorted().map {
            CGRect(x: 0, y: $0, width: width, height: bandHeight)
        }
    }

    private func consensusOffset(in offsets: [CGFloat], minimumCount: Int) -> ScrollOffsetEstimate? {
        guard !offsets.isEmpty else { return nil }
        var best: [CGFloat] = []
        for offset in offsets {
            let group = offsets.filter { abs($0 - offset) <= agreementTolerance }
            if group.count > best.count { best = group }
        }
        guard best.count >= minimumCount else { return nil }
        let average = best.reduce(0, +) / CGFloat(best.count)
        return ScrollOffsetEstimate(offsetPx: average, confidence: 0.9)
    }

    private struct DownsampledComparison {
        let current: [UInt8]
        let previous: [UInt8]
        let width: Int
        let height: Int
    }

    /// 分块一致性校验：固定标题栏等局部失配只占少数块，无关画面则多数块失配。
    private func hasMatchingContent(
        _ comparison: DownsampledComparison,
        offsetPx: CGFloat,
        sourceHeight: Int
    ) -> Bool {
        let shift = Int(
            (offsetPx * CGFloat(comparison.height) / CGFloat(max(sourceHeight, 1))).rounded()
        )
        // ± 仅吸收位图行方向差异，不参与滚动方向判定；方向由 Vision 的 ty 决定。
        return [shift, -shift].contains { matchingTiles(comparison, shift: $0) }
    }

    private func downsampledComparison(current: CGImage, previous: CGImage) -> DownsampledComparison? {
        guard let currentPixels = downsampledPixels(of: current),
              let previousPixels = downsampledPixels(of: previous) else { return nil }
        return DownsampledComparison(
            current: currentPixels,
            previous: previousPixels,
            width: max(1, current.width / validationDownsampleScale),
            height: max(1, current.height / validationDownsampleScale)
        )
    }

    private func downsampledPixels(of image: CGImage) -> [UInt8]? {
        let width = max(1, image.width / validationDownsampleScale)
        let height = max(1, image.height / validationDownsampleScale)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return Array(UnsafeBufferPointer(start: base, count: width * height * 4))
    }

    /// 块判定只看重叠区，且只统计有动态范围的块；返回匹配块占比是否达到阈值。
    private func matchingTiles(_ comparison: DownsampledComparison, shift: Int) -> Bool {
        let height = comparison.height
        let width = comparison.width
        let startRow = max(0, -shift)
        let endRow = min(height, height - shift)
        guard endRow - startRow >= validationTileSize else { return false }

        let bytesPerRow = width * 4
        var activeTiles = 0
        var matchedTiles = 0
        var tileTop = ((startRow + validationTileSize - 1) / validationTileSize) * validationTileSize
        while tileTop + validationTileSize <= endRow {
            let tileBottom = tileTop + validationTileSize
            var tileLeft = 0
            while tileLeft < width {
                let tileRight = min(tileLeft + validationTileSize, width)
                var difference = 0
                var samples = 0
                var minimum = 255
                var maximum = 0
                for row in tileTop..<tileBottom {
                    let currentRow = row * bytesPerRow
                    let previousRow = (row + shift) * bytesPerRow
                    for column in tileLeft..<tileRight {
                        let currentIndex = currentRow + column * 4
                        let previousIndex = previousRow + column * 4
                        for channel in 0..<3 {
                            let currentValue = Int(comparison.current[currentIndex + channel])
                            let previousValue = Int(comparison.previous[previousIndex + channel])
                            difference += abs(currentValue - previousValue)
                            samples += 1
                            minimum = min(minimum, min(currentValue, previousValue))
                            maximum = max(maximum, max(currentValue, previousValue))
                        }
                    }
                }
                if maximum - minimum >= minimumTileActivityRange {
                    activeTiles += 1
                    if CGFloat(difference) / CGFloat(max(samples, 1)) <= tileMatchDifferenceThreshold {
                        matchedTiles += 1
                    }
                }
                tileLeft += validationTileSize
            }
            tileTop += validationTileSize
        }

        guard activeTiles >= minimumActiveTileCount else { return false }
        return CGFloat(matchedTiles) / CGFloat(activeTiles) >= matchingTileFractionThreshold
    }

    private func translation(
        from current: CGImage,
        to previous: CGImage
    ) -> (x: CGFloat, y: CGFloat, confidence: Float)? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: previous)
        let handler = VNImageRequestHandler(cgImage: current, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return nil
        }
        return (
            x: observation.alignmentTransform.tx,
            y: observation.alignmentTransform.ty,
            confidence: observation.confidence
        )
    }
}
