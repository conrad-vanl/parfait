import SwiftUI

struct RecordDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Theme.raspberry)
            .frame(width: 10, height: 10)
            .opacity(pulsing ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

struct LevelMeter: View {
    /// 0...1
    var level: Float
    private let barCount = 12

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Float(i) / Float(barCount) < level ? Theme.mint : Color.secondary.opacity(0.2))
                    .frame(width: 4, height: 4 + CGFloat(i) * 1.2)
            }
        }
        .animation(.linear(duration: 0.1), value: level)
    }
}

struct StateBadge: View {
    let meeting: Meeting
    let stage: String?

    var body: some View {
        switch meeting.state {
        case .recording:
            Label("Recording", systemImage: "record.circle")
                .badgeStyle(Theme.raspberry)
        case .processing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(stage ?? "Processing…")
            }
            .badgeStyle(Theme.honey)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle")
                .badgeStyle(.orange)
        case .ready:
            EmptyView()
        }
    }
}

/// Only flags the exception: output produced by Claude (your account, off-device).
/// On-device is the default and needs no chip.
struct ProviderBadge: View {
    let provider: String?

    var body: some View {
        if provider == "claude" {
            Label("Claude", systemImage: "sparkles")
                .badgeStyle(Theme.blueberry)
        }
    }
}

struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.parfait(11, .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: 160, alignment: .leading)
            .background(Theme.honey.opacity(0.16), in: Capsule())
            .foregroundStyle(.primary)
    }
}

/// Wraps attendee-style chips onto new rows instead of overflowing the container width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension View {
    func badgeStyle(_ color: Color) -> some View {
        font(.parfait(11, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.13), in: Capsule())
    }

    func cardStyle() -> some View {
        modifier(CardBackground())
    }
}

struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }
}

/// The layered-glass motif used in empty states.
struct ParfaitStripes: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.cream)
            Rectangle().fill(Theme.honey)
            Rectangle().fill(Theme.raspberry)
            Rectangle().fill(Theme.blueberry)
        }
        .frame(width: 44, height: 56)
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: 8, bottomLeadingRadius: 18,
            bottomTrailingRadius: 18, topTrailingRadius: 8))
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 8, bottomLeadingRadius: 18,
                bottomTrailingRadius: 18, topTrailingRadius: 8)
            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            ParfaitStripes()
            Text(title).font(.parfait(17, .semibold))
            Text(message)
                .font(.parfait(13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Keeps a live transcript ScrollView pinned to its bottom anchor while the user is at
/// (or near) the bottom; scrolling up holds their place until they scroll back down or
/// tap "Jump to latest". Apply to the ScrollView, with a `ScrollViewReader` at the call
/// site providing the proxy and a view inside the content carrying `anchor` as its id.
struct LiveTranscriptPinning: ViewModifier {
    let anchor: String
    let segmentCount: Int
    let volatileText: String
    let proxy: ScrollViewProxy
    @Environment(\.colorScheme) private var scheme
    @State private var followsLive = true

    func body(content: Content) -> some View {
        content
            .onAppear {
                // A rebuilt view (the floating card hidden and re-shown, or the
                // Transcript tab re-opened mid-recording) starts at the top of
                // the accumulated transcript — resume the live tail instead.
                followsLive = true
                proxy.scrollTo(anchor, anchor: .bottom)
            }
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { old, new in
                // Content growth must never unpin: the geometry event carries the new
                // contentSize before the compensating scrollTo below has run, so the
                // stale offset would read as "scrolled away from the bottom". Only
                // user scrolls (offset changes at stable size) may change followsLive.
                guard abs(new.contentSize.height - old.contentSize.height) <= 0.5 else { return }
                let nearBottom = new.contentOffset.y + new.containerSize.height >=
                    new.contentSize.height + new.contentInsets.bottom - 40
                if followsLive != nearBottom { followsLive = nearBottom }
            }
            .onChange(of: segmentCount) {
                if followsLive { proxy.scrollTo(anchor, anchor: .bottom) }
            }
            .onChange(of: volatileText) {
                if followsLive { proxy.scrollTo(anchor, anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if !followsLive {
                    Button {
                        followsLive = true
                        proxy.scrollTo(anchor, anchor: .bottom)
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(.parfait(11, .semibold))
                            .foregroundStyle(Theme.ink(scheme))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.surface(scheme), in: Capsule())
                            .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                }
            }
    }
}

extension View {
    func liveTranscriptPinning(
        anchor: String, segmentCount: Int, volatileText: String, proxy: ScrollViewProxy
    ) -> some View {
        modifier(LiveTranscriptPinning(
            anchor: anchor, segmentCount: segmentCount, volatileText: volatileText, proxy: proxy))
    }
}

/// Minimal markdown display for summaries: headings, bullets, checkboxes,
/// inline bold/italic. Anything else renders as a plain paragraph.
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
                    id: \.offset) { _, rawLine in
                line(String(rawLine))
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func line(_ raw: String) -> some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 2)
        } else if trimmed.hasPrefix("# ") {
            inline(String(trimmed.dropFirst(2)))
                .font(.parfait(22, .bold))
                .padding(.top, 4)
        } else if trimmed.hasPrefix("## ") {
            inline(String(trimmed.dropFirst(3)))
                .font(.parfait(16, .bold))
                .foregroundStyle(Theme.raspberry)
                .padding(.top, 8)
        } else if trimmed.hasPrefix("### ") {
            inline(String(trimmed.dropFirst(4)))
                .font(.parfait(14, .semibold))
                .padding(.top, 4)
        } else if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: trimmed.hasPrefix("- [x] ") ? "checkmark.square.fill" : "square")
                    .foregroundStyle(Theme.honey)
                    .font(.system(size: 12))
                inline(String(trimmed.dropFirst(6)))
            }
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(Theme.honey).frame(width: 5, height: 5)
                    .padding(.top, 5)
                inline(String(trimmed.dropFirst(2)))
            }
        } else {
            inline(trimmed)
        }
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}
