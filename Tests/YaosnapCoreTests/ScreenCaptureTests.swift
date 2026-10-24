import CoreGraphics
import Testing
@testable import YaosnapCore

struct ScreenCaptureTests {
    @Test(.enabled(if: ScreenCaptureService.hasPermission()))
    func captureReturnsAtLeastOneDisplay() {
        let shots = ScreenCaptureService.captureAllDisplays()
        #expect(!shots.isEmpty)

        for shot in shots {
            #expect(shot.image.width > 0)
            #expect(shot.image.height > 0)
            // 图像宽高比应与显示区域一致（允许 Retina 缩放差异）
            let imageAspect = CGFloat(shot.image.width) / CGFloat(shot.image.height)
            let boundsAspect = shot.bounds.width / shot.bounds.height
            #expect(abs(imageAspect - boundsAspect) < 0.01)
        }
    }

    // 无权限时捕获返回空数组，不抛错、不崩溃
    @Test(.enabled(if: !ScreenCaptureService.hasPermission()))
    func captureWithoutPermissionReturnsEmpty() {
        #expect(ScreenCaptureService.captureAllDisplays().isEmpty)
    }

    // scale 由图像像素宽 / 屏幕点宽推导（Retina 3024px / 1512pt = 2）
    @Test func deriveScaleFromImageWidth() {
        let scale = ScreenCaptureService.deriveScale(
            for: 999_999,
            imageWidth: 3024,
            bounds: CGRect(x: 0, y: 0, width: 1512, height: 900)
        )
        #expect(scale == 2)
    }

    // 屏幕宽度为 0 时不能除零，退回 1
    @Test func deriveScaleFallsBackWhenBoundsWidthIsZero() {
        let scale = ScreenCaptureService.deriveScale(
            for: 999_999,
            imageWidth: 100,
            bounds: CGRect(x: 0, y: 0, width: 0, height: 0)
        )
        #expect(scale == 1)
    }
}
