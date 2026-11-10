import CoreGraphics
import Foundation
import YaosnapCore

func makeImage(width: Int, height: Int, pattern: (Int, Int) -> UInt8) -> CGImage {
    let bytesPerRow = width * 4
    var data = [UInt8](repeating: 0, count: bytesPerRow * height)
    for y in 0..<height {
        for x in 0..<width {
            let i = y * bytesPerRow + x * 4
            let v = pattern(x, y)
            data[i] = v
            data[i + 1] = v
            data[i + 2] = v
            data[i + 3] = 255
        }
    }
    let provider = CGDataProvider(data: Data(data) as CFData)!
    return CGImage(
        width: width, height: height,
        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )!
}

let estimator = ScrollOffsetEstimator()

var seed: UInt32 = 7
func noise(_ x: Int, _ y: Int) -> UInt8 {
    seed = seed &* 1_664_525 &+ 1_013_904_223 &+ UInt32(x &* 31 &+ y &* 17)
    return UInt8((seed >> 16) & 0xFF)
}

let noisy = makeImage(width: 800, height: 600, pattern: noise)
if let same = estimator.estimate(current: noisy, previous: noisy) {
    print("STATIC-NOISE offset=\(same.offsetPx) confidence=\(same.confidence)")
} else {
    print("STATIC-NOISE nil")
}

let striped = makeImage(width: 800, height: 600) { x, _ in (x / 8) % 2 == 0 ? 0 : 255 }
if let same = estimator.estimate(current: striped, previous: striped) {
    print("STATIC-STRIPE offset=\(same.offsetPx) confidence=\(same.confidence)")
} else {
    print("STATIC-STRIPE nil")
}

let blank = makeImage(width: 800, height: 600) { _, _ in 240 }
if let same = estimator.estimate(current: blank, previous: blank) {
    print("STATIC-BLANK offset=\(same.offsetPx) confidence=\(same.confidence)")
} else {
    print("STATIC-BLANK nil")
}

let offset10 = noisy.cropping(to: CGRect(x: 0, y: 10, width: 800, height: 560))!
let first = noisy.cropping(to: CGRect(x: 0, y: 0, width: 800, height: 560))!
if let moved = estimator.estimate(current: offset10, previous: first) {
    print("SHIFT-10 offset=\(moved.offsetPx) confidence=\(moved.confidence)")
} else {
    print("SHIFT-10 nil")
}