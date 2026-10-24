import Foundation
import Testing
@testable import YaosnapCore

struct AnnotationTests {
    private let style = Style(color: RGBAColor(r: 1, g: 0, b: 0), pen: .p3)

    private func roundTrip(_ shape: Shape) throws -> Annotation {
        let annotation = Annotation(shape: shape, style: style)
        let data = try JSONEncoder().encode(annotation)
        return try JSONDecoder().decode(Annotation.self, from: data)
    }

    @Test func codableRoundTripAllShapes() throws {
        let shapes: [Shape] = [
            .rect(CGRect(x: 1, y: 2, width: 30, height: 40)),
            .roundedRect(CGRect(x: 1, y: 2, width: 30, height: 40), radius: 6),
            .ellipse(CGRect(x: 0, y: 0, width: 10, height: 12)),
            .line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 20)),
            .arrow(from: CGPoint(x: 3, y: 4), to: CGPoint(x: -1, y: 9)),
            .polyline([CGPoint(x: 1, y: 1), CGPoint(x: 4, y: 7), CGPoint(x: 9, y: 3)]),
            .brush([CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5), CGPoint(x: 9, y: 1)]),
            .marker([CGPoint(x: 2, y: 2), CGPoint(x: 8, y: 8)]),
            .mosaic([CGPoint(x: 4, y: 4)]),
            .blur([CGPoint(x: 4, y: 4), CGPoint(x: 9, y: 6)]),
            .text("Hi", origin: CGPoint(x: 6, y: 8), fontSize: 22, rotation: 0.5),
            .serial(value: 3, center: CGPoint(x: 20, y: 30), radius: 14),
        ]
        for shape in shapes {
            let decoded = try roundTrip(shape)
            #expect(decoded.shape == shape, "\(shape) 编解码后应相等")
            #expect(decoded.style == style)
        }
    }

    @Test func codableRoundTripKeepsID() throws {
        let annotation = Annotation(shape: .rect(CGRect(x: 0, y: 0, width: 5, height: 5)), style: style)
        let data = try JSONEncoder().encode(annotation)
        let decoded = try JSONDecoder().decode(Annotation.self, from: data)
        #expect(decoded.id == annotation.id)
    }

    @Test func kindDerivation() {
        let cases: [(Shape, ShapeKind)] = [
            (.rect(.zero), .rect),
            (.roundedRect(.zero, radius: 1), .roundedRect),
            (.ellipse(.zero), .ellipse),
            (.line(from: .zero, to: .zero), .line),
            (.arrow(from: .zero, to: .zero), .arrow),
            (.polyline([.zero, CGPoint(x: 1, y: 1)]), .polyline),
            (.brush([]), .brush),
            (.marker([]), .marker),
            (.mosaic([]), .mosaic),
            (.blur([]), .blur),
            (.text("", origin: .zero, fontSize: 14, rotation: 0), .text),
            (.serial(value: 1, center: .zero, radius: 10), .serial),
        ]
        for (shape, kind) in cases {
            #expect(shape.kind == kind)
        }
    }

    @Test func penSizeLineWidthMapping() {
        let expected: [PenSize: CGFloat] = [
            .p1: 2, .p2: 3.5, .p3: 5, .p4: 7, .p5: 10,
        ]
        #expect(PenSize.allCases.count == 5)
        for (pen, width) in expected {
            #expect(pen.lineWidth == width)
        }
    }

    @Test func penSizeMosaicBlockMapping() {
        let expected: [PenSize: CGFloat] = [
            .p1: 8, .p2: 12, .p3: 16, .p4: 24, .p5: 32,
        ]
        for (pen, block) in expected {
            #expect(pen.mosaicBlock == block)
        }
    }

    @Test func penSizeTextFontSizeMapping() {
        let expected: [PenSize: CGFloat] = [
            .p1: 14, .p2: 18, .p3: 22, .p4: 28, .p5: 36,
        ]
        for (pen, size) in expected {
            #expect(pen.textFontSize == size)
        }
    }

    @Test func paletteHasTwelveColors() {
        #expect(RGBAColor.palette.count == 12)
        #expect(RGBAColor.palette.allSatisfy { $0.a == 1 })
    }
}
