import SwiftUI

/// Edge fade for bounded lists: marks hidden content and clears once the list reaches that edge.
struct OverflowFadeMask: ViewModifier {
    /// Short enough to read as an edge treatment rather than as a dimmed final row.
    var band: CGFloat = 24
    var includesTop = false

    /// Content hidden beyond each visible edge, 0 while the list rests against it.
    @State private var overflow = Overflow()

    private struct Overflow: Equatable {
        var top: CGFloat = 0
        var bottom: CGFloat = 0
    }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Overflow.self) { geo in
                Overflow(
                    top: geo.contentOffset.y + geo.contentInsets.top,
                    bottom: geo.contentSize.height + geo.contentInsets.bottom
                        - geo.containerSize.height - geo.contentOffset.y)
            } action: { _, new in
                overflow = Overflow(top: max(0, new.top), bottom: max(0, new.bottom))
            }
            .mask(
                GeometryReader { geo in
                    LinearGradient(
                        stops: stops(height: geo.size.height),
                        startPoint: .top, endPoint: .bottom
                    )
                }
            )
    }

    private func stops(height: CGFloat) -> [Gradient.Stop] {
        guard includesTop else { return bottomStops(height: height) }
        // Popup edges use several stops so neither end cuts abruptly through a row.
        let topStrength = min(overflow.top / band, 1)
        let bottomStrength = min(overflow.bottom / band, 1)
        guard max(topStrength, bottomStrength) > 0, height > 0 else {
            return [.init(color: .black, location: 0)]
        }
        let extent = min(band / height, 0.5)

        let topOpacity1: Double = 1 - topStrength
        let topOpacity2: Double = 1 - topStrength * 0.75
        let topOpacity3: Double = 1 - topStrength * 0.25
        let bottomOpacity3: Double = 1 - bottomStrength * 0.25
        let bottomOpacity2: Double = 1 - bottomStrength * 0.75
        let bottomOpacity1: Double = 1 - bottomStrength

        let loc1: CGFloat = extent * 0.35
        let loc2: CGFloat = extent * 0.7
        let loc3: CGFloat = extent
        let loc4: CGFloat = 1 - extent
        let loc5: CGFloat = 1 - extent * 0.7
        let loc6: CGFloat = 1 - extent * 0.35

        return [
            .init(color: .black.opacity(topOpacity1), location: 0),
            .init(color: .black.opacity(topOpacity2), location: loc1),
            .init(color: .black.opacity(topOpacity3), location: loc2),
            .init(color: .black, location: loc3),
            .init(color: .black, location: loc4),
            .init(color: .black.opacity(bottomOpacity3), location: loc5),
            .init(color: .black.opacity(bottomOpacity2), location: loc6),
            .init(color: .black.opacity(bottomOpacity1), location: 1)
        ]
    }

    /// The original Settings and Notes curve stays unchanged when no popup opts into its top edge.
    private func bottomStops(height: CGFloat) -> [Gradient.Stop] {
        let strength = min(overflow.bottom / band, 1)
        guard strength > 0, height > band else { return [.init(color: .black, location: 0)] }
        return [
            .init(color: .black, location: 0),
            .init(color: .black, location: 1 - band / height),
            .init(color: .black.opacity(1 - strength), location: 1)
        ]
    }
}

extension View {
    /// Attach before `thinScrollbar`. Not `edgeDissolve`, which is tuned to the palette's bars.
    func overflowFade(band: CGFloat = 24, includingTop: Bool = false) -> some View {
        modifier(OverflowFadeMask(band: band, includesTop: includingTop))
    }
}
