import CoreGraphics
import Testing
@testable import YaosnapCore

struct RectMathTests {
    // 反向拖拽（右下 → 左上）归一化为正矩形
    @Test func normalizedRectFromReverseDrag() {
        let r = RectMath.normalizedRect(from: CGPoint(x: 300, y: 200), to: CGPoint(x: 100, y: 50))
        #expect(r == CGRect(x: 100, y: 50, width: 200, height: 150))
    }

    // 零尺寸拖拽得到零尺寸矩形，不外扩
    @Test func normalizedRectZeroSize() {
        let r = RectMath.normalizedRect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 10))
        #expect(r == CGRect(x: 10, y: 10, width: 0, height: 0))
    }

    // 越界裁剪到屏幕内
    @Test func clampToBounds() {
        let r = RectMath.clamp(
            CGRect(x: -50, y: -20, width: 200, height: 100),
            to: CGRect(x: 0, y: 0, width: 100, height: 60)
        )
        #expect(r == CGRect(x: 0, y: 0, width: 100, height: 60))
    }

    // 全局坐标(左上原点) → 视图坐标(左下原点)
    // 显示区域 origin=(1512,0)，高 900；窗口内 y=0（全局顶部）应映射到视图 y=900-矩形高
    @Test func globalToViewRectFlipsY() {
        let global = CGRect(x: 1512, y: 0, width: 100, height: 50)
        let display = CGRect(x: 1512, y: 0, width: 1512, height: 900)
        let view = RectMath.toViewRect(globalRect: global, displayBounds: display, viewHeight: 900)
        #expect(view == CGRect(x: 0, y: 850, width: 100, height: 50))
    }

    // 视图矩形 → 冻结图像素矩形（Retina scale=2 时乘 2，且 y 翻转）
    @Test func imageRectWithScaleAndFlip() {
        let viewRect = CGRect(x: 10, y: 20, width: 100, height: 50)
        let image = RectMath.imageRect(fromViewRect: viewRect, viewHeight: 900, scale: 2)
        #expect(image == CGRect(x: 20, y: 1660, width: 200, height: 100))
    }
}
