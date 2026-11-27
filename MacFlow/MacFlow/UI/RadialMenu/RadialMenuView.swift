import AppKit
import SwiftUI

// ───────────────────────────────────────────────────────────────────────
// MARK: – RadialMenuView
// ───────────────────────────────────────────────────────────────────────
/// Transparent, cursor-local radial wheel. Every gap between segments is a
/// true hole through to the desktop.
struct RadialMenuView: View {
    @ObservedObject var viewModel: RadialMenuViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var config: RadialMenuConfiguration { viewModel.config }
    private var outerRadius: CGFloat { config.radius }
    private var innerRadius: CGFloat { config.innerRadius }

    static func layoutSize(for config: RadialMenuConfiguration = .default) -> CGSize {
        let d = config.radius * 2 + 58
        return CGSize(width: d, height: d + 14)
    }

    var body: some View {
        let size = Self.layoutSize(for: config)
        ZStack {
            Color.clear
            Group {
                if viewModel.isEmpty { emptyRing } else { radialWheel }
                centerView
            }
            .frame(width: size.width, height: size.width)
            .position(x: size.width / 2, y: size.width / 2)
            subtitleView
                .frame(width: size.width - 12)
                .position(x: size.width / 2, y: size.height - 14)
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(viewModel.isVisible ? 1 : (reduceMotion ? 1 : 0.9))
        .opacity(viewModel.isVisible ? 1 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MacFlow \(viewModel.mode.displayName)")
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.78)) {
                viewModel.isVisible = true
            }
        }
    }

    // MARK: – Wheel

    private var radialWheel: some View {
        ZStack {
            ForEach(Array(viewModel.segments.enumerated()), id: \.element.id) { idx, seg in
                segmentView(segment: seg, index: idx, total: viewModel.segments.count)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .id(viewModel.page)
        .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity),
                                removal: .scale(scale: 1.06).combined(with: .opacity)))
    }

    /// Shown when nothing applies: a quiet, seamless ring so the drop target
    /// is still visible while the subtitle explains why.
    private var emptyRing: some View {
        let ring = RingShape(inner: innerRadius, outer: outerRadius)
        return Group {
            if #available(macOS 26.0, *) {
                ring.fill(Color.white.opacity(0.02)).glassEffect(.clear, in: ring)
            } else {
                ring.fill(.ultraThinMaterial)
            }
        }
        .opacity(0.6)
    }

    // MARK: – Single Segment

    private func segmentView(segment: RadialSegment, index: Int, total: Int) -> some View {
        let startA = segmentStartAngle(index: index, total: total)
        let endA   = segmentEndAngle(index: index, total: total)
        let hovered = viewModel.hoveredSegmentID == segment.id

        let shape = SegmentShape(
            startAngle: startA,
            endAngle: endA,
            innerRadius: innerRadius,
            outerRadius: outerRadius,
            outerCornerRadius: 18,
            innerCornerRadius: 8
        )

        return ZStack {
            segmentSurface(shape: shape, isHovered: hovered)
            segmentContent(segment: segment, midAngle: (startA + endA) / 2, isHovered: hovered)
        }
        .scaleEffect(hovered ? 1.03 : 1.0)
        .zIndex(hovered ? 1 : 0)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: hovered)
        .accessibilityElement()
        .accessibilityLabel(segment.subtitle)
        .accessibilityAddTraits(hovered ? .isSelected : [])
    }

    // MARK: – Surface (Glass + Highlight)

    @ViewBuilder
    private func segmentSurface(shape: SegmentShape, isHovered: Bool) -> some View {
        if #available(macOS 26.0, *) {
            // Native Apple Liquid Glass. No backing disc: the space around
            // every segment stays physically transparent.
            shape
                .fill(Color.white.opacity(isHovered ? 0.09 : 0.045))
                .glassEffect(
                    isHovered
                        ? .clear.tint(config.accentColor).interactive(true)
                        : .clear,
                    in: shape
                )
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay {
                    shape.fill(isHovered
                               ? config.accentColor.opacity(0.68)
                               : Color.white.opacity(0.04))
                }
        }
    }

    // MARK: – Label + Icon

    private func segmentContent(segment: RadialSegment, midAngle: Double, isHovered: Bool) -> some View {
        let labelRadius = (innerRadius + outerRadius) / 2 + 2
        let x =  labelRadius * CGFloat(sin(midAngle))
        let y = -labelRadius * CGFloat(cos(midAngle))

        return VStack(spacing: 5) {
            if let symbol = segment.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(segment.label)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.62)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text(segment.label)
                    .font(.system(size: 13, weight: .bold))
                    .tracking(0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .foregroundStyle(isHovered ? Color.white : Color.primary.opacity(0.86))
        .frame(width: 76)
        .offset(x: x, y: y)
    }

    // MARK: – Center Disc

    private var centerView: some View {
        Group {
            if #available(macOS 26.0, *) {
                Circle()
                    .fill(Color.white.opacity(0.012))
                    .glassEffect(
                        .clear.tint(Color.white.opacity(0.13)),
                        in: Circle()
                    )
            } else {
                Circle().fill(.regularMaterial)
            }
        }
        // Smaller than the inner aperture: a clean breathing gap all around.
        .frame(width: 74, height: 74)
        .overlay {
            Text(viewModel.centerLabel)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.68)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .foregroundStyle(Color.primary.opacity(0.78))
                .frame(width: 54)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.12), value: viewModel.centerLabel)
        }
        .overlay(alignment: .topTrailing) {
            if viewModel.fileCountBadge > 1 {
                Text("\(viewModel.fileCountBadge)")
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(Capsule().fill(config.accentColor))
                    .offset(x: 2, y: 2)
            }
        }
    }

    // MARK: – Subtitle

    private var subtitleView: some View {
        Text(viewModel.subtitle)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.64))
            .lineLimit(1)
            .truncationMode(.middle)
            .opacity(viewModel.subtitle.isEmpty ? 0 : 1)
            .animation(.easeOut(duration: 0.14), value: viewModel.subtitle)
    }

    // MARK: – Angle helpers

    private func segmentStartAngle(index: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        let slice = (2 * Double.pi) / Double(total)
        return Double(index) * slice - slice / 2 + config.segmentGap.asRadians(at: outerRadius)
    }

    private func segmentEndAngle(index: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        let slice = (2 * Double.pi) / Double(total)
        return Double(index + 1) * slice - slice / 2 - config.segmentGap.asRadians(at: outerRadius)
    }
}

// ───────────────────────────────────────────────────────────────────────
// MARK: – SegmentShape  (smooth annular sector)
// ───────────────────────────────────────────────────────────────────────
/// Annular-sector wedge with rounded corners.
struct SegmentShape: Shape, InsettableShape {
    let startAngle: Double
    let endAngle: Double
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    let outerCornerRadius: CGFloat
    let innerCornerRadius: CGFloat

    private var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> SegmentShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let oR = max(outerRadius - insetAmount, 1)
        let iR = max(innerRadius + insetAmount, 1)
        let radialThickness = oR - iR
        guard radialThickness > 0 else { return Path() }

        let sweep = max(endAngle - startAngle, 0.001)
        // Corner radius capped so it never exceeds half the radial band or
        // half the arc length at the smaller radius.
        let maxR = min(radialThickness / 2.4,
                       iR * CGFloat(sweep) / 2.4,
                       oR * CGFloat(sweep) / 2.4)
        let outerCR = min(outerCornerRadius, maxR)
        let innerCR = min(innerCornerRadius, maxR)

        // Angular insets produced by the rounded corners at each radius.
        let outerInset = Double(outerCR / oR)
        let innerInset = Double(innerCR / iR)

        var p = Path()

        // ── Outer arc (clockwise in geometry = counterclockwise in SwiftUI's
        //    top-left coord system when using Angle values) ──
        let oStart = startAngle + outerInset
        let oEnd   = endAngle   - outerInset

        // Start at the outer-start corner, offset inward by cr.
        let pOuterStartInner = pt(center, oR - outerCR, startAngle)
        p.move(to: pOuterStartInner)

        // Outer-start rounded corner
        p.addQuadCurve(to: pt(center, oR, oStart),
                       control: pt(center, oR, startAngle))

        // Outer arc
        p.addArc(center: center, radius: oR,
                 startAngle: .radians(oStart - .pi / 2),
                 endAngle:   .radians(oEnd   - .pi / 2),
                 clockwise: false)

        // Outer-end rounded corner
        p.addQuadCurve(to: pt(center, oR - outerCR, endAngle),
                       control: pt(center, oR, endAngle))

        // ── Straight radial edge (outer→inner on end side) ──
        p.addLine(to: pt(center, iR + innerCR, endAngle))

        // Inner-end rounded corner
        let iEnd = endAngle - innerInset
        p.addQuadCurve(to: pt(center, iR, iEnd),
                       control: pt(center, iR, endAngle))

        // ── Inner arc (reverse direction) ──
        let iStart = startAngle + innerInset
        p.addArc(center: center, radius: iR,
                 startAngle: .radians(iEnd   - .pi / 2),
                 endAngle:   .radians(iStart - .pi / 2),
                 clockwise: true)

        // Inner-start rounded corner
        p.addQuadCurve(to: pt(center, iR + innerCR, startAngle),
                       control: pt(center, iR, startAngle))

        // ── Straight radial edge (inner→outer on start side) ──
        p.addLine(to: pOuterStartInner)

        p.closeSubpath()
        return p
    }

    /// Map (center, radius, angle) to screen point.  angle = 0 is top,
    /// increasing clockwise, matching the ViewModel's convention.
    private func pt(_ c: CGPoint, _ r: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: c.x + r * CGFloat(sin(angle)),
                y: c.y - r * CGFloat(cos(angle)))
    }
}

/// Full annulus without a seam.
struct RingShape: Shape {
    let inner: CGFloat
    let outer: CGFloat
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
        p.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
        return p.normalized(eoFill: true)
    }
}

private extension CGFloat {
    func asRadians(at radius: CGFloat) -> Double { Double(self / radius) }
}
