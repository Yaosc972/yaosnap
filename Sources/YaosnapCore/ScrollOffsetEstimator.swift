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
    /// Vision 对无关画面的置信度也可能报 1.0，需用像素一致性二次校验。
    private let maximumMeanChannelDifference: CGFloat = 12

    public init() {}

    public func estimate(current: CGImage, previous: CGImage) -> ScrollOffsetEstimate? {
        guard current.width == previous.width,
              current.height == previous.height,
              current.width > 0,
              current.height > 0 else { return nil }

        let frameHeight = CGFloat(current.height)
        let bands = comparisonBands(width: current.width, height: current.height)

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
           hasMatchingContent(current: current, previous: previous, offset: consensus.offsetPx) {
            return consensus
        }

        guard let full = translation(from: current, to: previous),
              abs(full.y) <= frameHeight * (1 - minimumOverlapFraction),
              hasMatchingContent(current: current, previous: previous, offset: full.y) else { return nil }
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

    /// 按候选偏移对齐重叠区，比较像素平均通道差；无关画面差异远高于阈值。
    private func hasMatchingContent(current: CGImage, previous: CGImage, offset: CGFloat) -> Bool {
        guard let currentPixels = rgbaPixels(of: current),
              let previousPixels = rgbaPixels(of: previous) else { return false }
        let shift = Int(offset.rounded())
        let quality = [shift, -shift]
            .compactMap {
                meanChannelDifference(
                    currentPixels,
                    previousPixels,
                    width: current.width,
                    height: current.height,
                    shift: $0
                )
            }
            .min()
        guard let quality else { return false }
        return quality <= maximumMeanChannelDifference
    }

    /// 位图坐标不翻转：两张图同样绘制，行对应关系只差一个符号，故上面同时尝试 ±shift。
    private func rgbaPixels(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return Array(UnsafeBufferPointer(start: base, count: width * height * 4))
    }

    private func meanChannelDifference(
        _ current: [UInt8],
        _ previous: [UInt8],
        width: Int,
        height: Int,
        shift: Int
    ) -> CGFloat? {
        let start = max(0, -shift)
        let end = min(height, height - shift)
        guard end - start >= height / 10 else { return nil }
        let bytesPerRow = width * 4
        var total = 0
        var count = 0
        var y = start
        while y < end {
            let currentRow = y * bytesPerRow
            let previousRow = (y + shift) * bytesPerRow
            var x = 0
            while x < width {
                total += abs(Int(current[currentRow + x * 4]) - Int(previous[previousRow + x * 4]))
                count += 1
                x += 2
            }
            y += 2
        }
        guard count > 0 else { return nil }
        return CGFloat(total) / CGFloat(count)
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
