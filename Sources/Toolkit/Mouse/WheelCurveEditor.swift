import SwiftUI

/// How far a notch scrolls, as the graph the wheel tap follows: across, how
/// fast the wheel spins; up, the points a notch goes. The left end is a single
/// notch, the right end a fast spin; with a curve, a handle in the middle
/// bends it. Drawn with shapes: a redrawing
/// Canvas keeps graphics memory (see System Stats).
struct WheelCurveEditor: View {
    @Binding var start: Double
    @Binding var end: Double
    @Binding var bend: Double
    let curved: Bool

    private static let range = Profile.scrollDistanceRange
    private static let bends: ClosedRange<Double> = 1...4
    private static let height: CGFloat = 120
    private static let space = "wheel-curve"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("A notch scrolls \(Self.points(start)), a fast spin \(Self.points(end))")
                    .font(.callout)
                Spacer()
                Text(curved ? "Drag the ends and the middle" : "Drag the ends")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            GeometryReader { geometry in
                let plot = CGRect(origin: .zero, size: geometry.size).insetBy(dx: 7, dy: 7)
                ZStack(alignment: .topLeading) {
                    Grid(range: Self.range)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        .frame(width: plot.width, height: plot.height)
                        .offset(x: plot.minX, y: plot.minY)
                    Line(points: (0...40).map { Double($0) / 40 }.map { point($0, further(at: $0), in: plot) })
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    handle(at: point(0, start, in: plot))
                        .gesture(drag(in: plot) { points in start = min(points, end) })
                    handle(at: point(1, end, in: plot))
                        .gesture(drag(in: plot) { points in end = max(points, start) })
                    if curved {
                        handle(at: point(0.5, further(at: 0.5), in: plot))
                            .gesture(drag(in: plot) { points in bend = bend(for: points) })
                    }
                }
                .coordinateSpace(name: Self.space)
            }
            .frame(height: Self.height)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack {
                Text("A single notch")
                Spacer()
                Text("A fast spin")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func further(at pace: Double) -> Double {
        WheelEngine.further(start: start, end: end, bend: bend, curved: curved, at: pace)
    }

    private func point(_ pace: Double, _ points: Double, in plot: CGRect) -> CGPoint {
        let share = (points - Self.range.lowerBound) / (Self.range.upperBound - Self.range.lowerBound)
        return CGPoint(x: plot.minX + pace * plot.width, y: plot.maxY - share * plot.height)
    }

    private func handle(at point: CGPoint) -> some View {
        Circle()
            .fill(Color.accentColor)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
            .frame(width: 12, height: 12)
            // A bigger target than it looks.
            .padding(6)
            .contentShape(Circle())
            .position(point)
    }

    /// Where the pointer is, in points, in fives.
    private func drag(in plot: CGRect, _ moved: @escaping (Double) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)).onChanged { value in
            let share = (plot.maxY - value.location.y) / plot.height
            let points = Self.range.lowerBound + share * (Self.range.upperBound - Self.range.lowerBound)
            moved((min(max(points, Self.range.lowerBound), Self.range.upperBound) / 5).rounded() * 5)
        }
    }

    /// The bend that puts the middle of the curve at `points`.
    private func bend(for points: Double) -> Double {
        guard end - start > 0.01 else { return bend }
        let share = min(max((points - start) / (end - start), 0.0625), 0.5)
        let value = log(share) / log(0.5)
        return (min(max(value, Self.bends.lowerBound), Self.bends.upperBound) * 20).rounded() / 20
    }

    static func points(_ value: Double) -> String {
        String(localized: "\(Int(value.rounded())) pt")
    }

    /// Faint lines every 50 points.
    private struct Grid: Shape {
        let range: ClosedRange<Double>
        func path(in rect: CGRect) -> Path {
            var path = Path()
            for step in stride(from: 50.0, through: range.upperBound, by: 50) {
                let y = rect.maxY - (step - range.lowerBound) / (range.upperBound - range.lowerBound) * rect.height
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            return path
        }
    }

    private struct Line: Shape {
        let points: [CGPoint]
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.addLines(points)
            return path
        }
    }
}
