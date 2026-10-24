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
}
