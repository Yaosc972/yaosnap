import AppKit
import YaosnapCore

/// 标注画布。frame 等于选区矩形，因此自身坐标即画布坐标（原点在选区左下，y 向上），
/// 与导出侧 flatten 建的上下文坐标语义一致。
/// 不接 AppKit 事件：hitTest 返回 nil 让鼠标穿透到 OverlayView，由它推进状态机。
@MainActor
final class AnnotationCanvas: NSView {
    private let base: CGImage
    private let cropOriginPx: CGPoint
    private let scale: CGFloat

    var annotations: [Annotation] = [] {
        didSet { needsDisplay = true }
    }
    /// 正在拖拽、尚未提交的形状。
    var draft: Annotation? {
        didSet { needsDisplay = true }
    }
    /// 二次编辑选中的标注。高亮只画在预览上，不进导出。
    var selectedID: UUID? {
        didSet { needsDisplay = true }
    }
    var currentStyle: Style {
        didSet { needsDisplay = true }
    }

    init(base: CGImage, cropOriginPx: CGPoint, scale: CGFloat, initialStyle: Style) {
        self.base = base
        self.cropOriginPx = cropOriginPx
        self.scale = scale
        self.currentStyle = initialStyle
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let input = RenderInput(
            base: base,
            cropOriginPx: cropOriginPx,
            canvasSize: bounds.size,
            scale: scale
        )
        AnnotationRenderer.draw(annotations, draft: draft, input: input, into: ctx)
        drawSelectionHighlight(in: ctx)
    }

    private func drawSelectionHighlight(in ctx: CGContext) {
        guard let id = selectedID,
              let shape = annotations.first(where: { $0.id == id })?.shape else { return }
        // 画布 frame 与选区重合，画布坐标即视图坐标，直接描在包围盒外扩 3pt 处。
        let box = shape.bounds.insetBy(dx: -3, dy: -3)
        ctx.saveGState()
        ctx.setStrokeColor(RGBAColor.palette[5].cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(box)
        ctx.restoreGState()
    }
}
