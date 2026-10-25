import CoreGraphics
import Foundation

/// 多选集合上的纯函数。选框命中与整组平移 / 删除放在 Core，
/// 交互层只负责状态机，便于单测覆盖边界情况。
public enum AnnotationSelection {
    /// 与选框相交的标注。包围盒相切也算命中；零宽 / 零高的线状标注同样按包围盒判断。
    public static func ids(in annotations: [Annotation], intersecting rect: CGRect) -> Set<UUID> {
        Set(annotations.filter { intersectsTouching($0.shape.bounds, rect) }.map(\.id))
    }

    /// 选中标注的整体包围盒。空集合返回 nil。
    public static func bounds(of annotations: [Annotation], ids: Set<UUID>) -> CGRect? {
        let boxes = annotations.lazy.filter { ids.contains($0.id) }.map(\.shape.bounds)
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { $0.union($1) }
    }

    /// 只平移选中标注，其余保持原 index 与顺序，平移后各标注包围盒位移一致。
    public static func translating(
        _ annotations: [Annotation],
        ids: Set<UUID>,
        by delta: CGPoint
    ) -> [Annotation] {
        annotations.map { annotation in
            guard ids.contains(annotation.id) else { return annotation }
            return Annotation(
                id: annotation.id,
                shape: annotation.shape.translated(by: delta),
                style: annotation.style
            )
        }
    }

    public static func removing(_ ids: Set<UUID>, from annotations: [Annotation]) -> [Annotation] {
        annotations.filter { !ids.contains($0.id) }
    }

    /// CGRect.intersects 在只共享边时为 false，而框选要求边界相切也算命中。
    private static func intersectsTouching(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX <= b.maxX && b.minX <= a.maxX && a.minY <= b.maxY && b.minY <= a.maxY
    }
}
