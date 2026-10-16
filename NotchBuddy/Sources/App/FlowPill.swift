#if !APPSTORE
import AppKit
import SwiftUI

/// The edge of the screen the pill lives on: centred on it, or where it was ⌥-dragged along it.
enum FlowPillEdge: String, CaseIterable, Identifiable {
    case bottom, left, right
    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottom: return String(localized: "flow.edge.bottom")
        case .left:   return String(localized: "flow.edge.left")
        case .right:  return String(localized: "flow.edge.right")
        }
    }
}

/// A message above the pill: something went wrong, or something is ready, with a button to act.
struct FlowAnnouncement: Equatable, Identifiable {
    let id = UUID()
    /// An SF Symbol.
    var symbol: String
    /// Its colour.
    var tint: String = "#FB923C"
    var text: String
    /// The button's title, if there is something to do.
    var action: String?
}

/// What the pill shows.
@MainActor
final class FlowPillModel: ObservableObject {
    enum Phase: Equatable {
        /// Resting: a small pill at the bottom of the screen, there as long as Flow dictation is on.
        case idle
        /// The key is held: the pill opens, Mochi on the left, the dots follow the voice.
        case listening
        /// Hands-free (double tap, or the pill's microphone): ✕, the dots and ✓, with an orange ring.
        case locked
        /// Released: the Mac turns the voice into words.
        case thinking
        /// No Accessibility permission: the words are on the clipboard.
        case copied
        /// The microphone or speech recognition could not start.
        case failed
        /// ⌃⌘V: the last dictation was pasted again.
        case pastedAgain
    }
    @Published var phase: Phase = .idle
    /// A call is being recorded by the Notetaker: resting, the pill shows it, with a stop button.
    @Published var noteStartedAt: Date?
    /// The pointer is over the pill: resting, it opens into its buttons.
    @Published var hovered = false
    /// The bubble above the pill while the pointer is on one of its buttons.
    @Published var tooltip: String?
    /// The message above the pill.
    @Published var announcement: FlowAnnouncement?
    /// The key to dictate ("⌥ de droite"), for the bubbles.
    @Published var keyLabel = ""
    /// Where the pill is: along the bottom, or standing on the left or right edge.
    @Published var edge: FlowPillEdge = .bottom
    /// The recorded call has passed an hour: the time needs a little more room.
    @Published var noteHours = false
    /// The side notch's cell whose button the tooltip belongs to, so the card points at it.
    @Published var tipCell: Int?
    /// The pill is being moved (⌥-drag): no hover and no bubbles meanwhile.
    @Published var dragging = false

    var stopNote: (@MainActor () -> Void)?
    var toggleNote: (@MainActor () -> Void)?
    var dictate: (@MainActor () -> Void)?
    var finishDictation: (@MainActor () -> Void)?
    var cancelDictation: (@MainActor () -> Void)?
    var openHub: (@MainActor () -> Void)?
    var announcementAction: (@MainActor () -> Void)?
    var dismissAnnouncement: (@MainActor () -> Void)?
}

/// Eases the dots toward the microphone's levels, frame by frame (fast up, slower down), and
/// makes them ripple while the Mac turns the voice into words.
final class FlowLevelSmoother {
    private var values = [Double](repeating: 0, count: FlowBands.count)
    private var last: Date?

    func frame(at date: Date, target: [Float]?, thinking: Bool) -> [Double] {
        let dt = min(0.1, last.map { date.timeIntervalSince($0) } ?? 1.0 / 60)
        last = date
        let t = date.timeIntervalSinceReferenceDate
        for i in values.indices {
            var goal: Double
            if thinking {
                // A small wave running through the dots.
                goal = 0.10 + 0.22 * max(0, sin(t * 7.5 - Double(i) * 0.75))
            } else {
                let level = Double(target?[safe: i] ?? 0)
                // A touch of life so a steady sound does not freeze the dots.
                goal = level * (0.86 + 0.14 * sin(t * 11 + Double(i) * 1.7))
            }
            let rate = goal > values[i] ? 28.0 : 10.0
            values[i] += (goal - values[i]) * min(1, rate * dt)
        }
        return values
    }

    func reset() {
        values = [Double](repeating: 0, count: FlowBands.count)
        last = nil
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// The pill at the bottom of the screen, like Wispr Flow's bar. Resting, it is a small see-through
/// pill; under the pointer it opens into Mochi and three buttons (dictate, record a call, open
/// Coucou), each with its bubble. When you speak it opens into Mochi and nine dots rising and
/// falling with the graves and the aigus of the voice. Messages (a paste that could not happen, a
/// call's notes ready) grow above it, with a button to act. On the left or right edge it is a black
/// notch welded to the screen's edge, its ends flaring into it, with everything in it stacked.
struct FlowPillView: View {
    @ObservedObject var model: FlowPillModel
    let bands: FlowAudioBands
    let smoother: FlowLevelSmoother

    /// The resting pill, lying along its edge.
    static let restingLength: CGFloat = 44
    static let restingThickness: CGFloat = 8
    static let openThickness: CGFloat = 34

    /// The notch on a side edge, with codenotch's measures (MIT, Copyright 2026 Vinz). They are
    /// pixels of its design frame, at 44/117 pt each.
    nonisolated static let sidePx: CGFloat = 44.0 / 117.0
    /// Resting: codenotch's folded pill, about 9.8 by 79 pt, its 2 pt bleed included.
    nonisolated static let sideRestingDepth: CGFloat = 26 * sidePx
    nonisolated static let sideRestingLength: CGFloat = 210 * sidePx
    /// Open: codenotch's body depth, about 70 pt.
    nonisolated static let sideOpenDepth: CGFloat = 186 * sidePx
    /// How far each end flares along the edge, and the corners on the inner side. The shape
    /// clamps both to the depth it has, which is what makes the resting notch a slim bar.
    nonisolated static let sideFlare: CGFloat = 103 * sidePx
    nonisolated static let sideCorner: CGFloat = 78.8 * sidePx
    /// How far the notch runs past the screen's edge, so no line of wallpaper shows along it.
    nonisolated static let sideBleed: CGFloat = 2
    /// How the notch opens and folds, and how its contents follow (codenotch's unfold and contents).
    nonisolated static let sideSpring = Animation.spring(response: 0.62, dampingFraction: 0.72)
    nonisolated static let sideContentSpring = Animation.spring(response: 0.48, dampingFraction: 0.8)

    /// What the capsule shows, from the most to the least important.
    enum Look: Equatable {
        case resting, toolbar, note, live, handsFree, message
    }

    /// What the side notch showed when it was last open.
    @State private var lastOpenLook: Look = .toolbar

    private var look: Look { Self.look(for: model) }

    static func look(for model: FlowPillModel) -> Look {
        switch model.phase {
        case .locked: return .handsFree
        case .listening, .thinking: return .live
        case .copied, .failed, .pastedAgain: return .message
        case .idle:
            if model.noteStartedAt != nil { return .note }
            return model.hovered ? .toolbar : .resting
        }
    }

    private var open: Bool { look != .resting }
    /// On the left or right edge, the pill stands up and everything in it is stacked.
    private var vertical: Bool { model.edge != .bottom }

    var body: some View {
        let size = FlowPillController.size(for: model.edge)
        Group {
            switch model.edge {
            case .bottom:
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    bubble
                    capsule
                }
            case .left:
                HStack(spacing: Self.sideCardSpacing) {
                    sideNotch
                    bubble
                    Spacer(minLength: 0)
                }
            case .right:
                HStack(spacing: Self.sideCardSpacing) {
                    Spacer(minLength: 0)
                    bubble
                    sideNotch
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: model.announcement)
        .animation(.easeOut(duration: 0.15), value: model.tooltip)
    }

    // MARK: Beside the pill

    /// Where the bubbles grow from: the pill's side.
    private var bubbleAnchor: UnitPoint {
        switch model.edge {
        case .bottom: return .bottom
        case .left:   return .leading
        case .right:  return .trailing
        }
    }

    /// A short message of the pill (pasted again, microphone off…): in the pill when it lies along
    /// the bottom, in a bubble beside it when it stands up.
    private var messageText: String? {
        switch model.phase {
        case .copied:      return String(localized: "flow.copied-noaccess")
        case .failed:      return String(localized: "flow.failed")
        case .pastedAgain: return String(localized: "flow.pasted-again")
        default:           return nil
        }
    }

    @ViewBuilder private var bubble: some View {
        if let announcement = model.announcement {
            FlowAnnouncementView(announcement: announcement, edge: model.edge,
                                 act: { model.announcementAction?() },
                                 dismiss: { model.dismissAnnouncement?() })
                .transition(.scale(scale: 0.6, anchor: bubbleAnchor).combined(with: .opacity))
        } else if vertical, let text = model.tooltip ?? messageText {
            // On the sides, a black card level with the button under the pointer, pointing at it.
            FlowSideCard(edge: model.edge) {
                Text(text)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Self.inkPrimary)
                    .padding(.horizontal, FlowSideCardShape.padding)
                    .frame(height: FlowSideCardShape.tooltipHeight)
            }
            .offset(y: model.tooltip == nil ? 0 : model.tipCell.map { Self.sideCellOffset($0, cells: Self.sideCells(sideLook)) } ?? 0)
            .transition(.scale(scale: 0.8, anchor: bubbleAnchor).combined(with: .opacity))
        } else if let text = model.tooltip {
            Text(text)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Capsule().fill(Color.black.opacity(0.94)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
                .fixedSize()
                .transition(.scale(scale: 0.8, anchor: bubbleAnchor).combined(with: .opacity))
        }
    }

    // MARK: The capsule (along the bottom)

    /// How long the open pill is, along the bottom, for what it shows.
    private var openLength: CGFloat {
        switch look {
        case .toolbar:   return 150
        case .note:      return model.noteHours ? 152 : 136
        case .handsFree: return 158
        case .message:   return Self.messageWidth(messageText ?? "")
        default:         return 118
        }
    }

    static func messageWidth(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let w = (text as NSString).size(withAttributes: [.font: font]).width
        return ceil(w) + 22 + 9 + 26 + 2
    }

    private var capsule: some View {
        let length = open ? openLength : Self.restingLength
        let thickness = open ? Self.openThickness : Self.restingThickness
        return ZStack {
            // Resting, the pill is see-through: whatever is behind it stays readable. Open, it is black.
            Capsule()
                .fill(Color.black.opacity(open ? 0.94 : 0.28))
            Capsule()
                .strokeBorder(Color.white.opacity(open ? 0.16 : 0.42), lineWidth: open ? 1 : 1.2)
            Capsule()
                .strokeBorder(Color(hex: "#F97316").opacity(look == .handsFree ? 0.85 : 0), lineWidth: 1.5)
            content
                .opacity(open ? 1 : 0)
                .scaleEffect(open ? 1 : 0.5)
                .animation(open ? .easeOut(duration: 0.2).delay(0.07) : .easeIn(duration: 0.1), value: open)
        }
        .frame(width: length, height: thickness)
        .clipShape(Capsule())          // the content stays inside while the pill opens
        .shadow(color: .black.opacity(open ? 0.35 : 0), radius: open ? 10 : 0, y: open ? 4 : 0)
        .animation(.spring(response: 0.36, dampingFraction: 0.74), value: look)
        .padding(.bottom, 2)
    }

    @ViewBuilder private var content: some View {
        switch look {
        case .toolbar:
            HStack(spacing: 4) {
                mochi.padding(.trailing, 5)
                PillButton(symbol: "mic.fill", tip: String(format: String(localized: "flow.tip.dictate %@"), model.keyLabel),
                           model: model) { model.dictate?() }
                PillButton(symbol: "record.circle", tip: String(localized: "flow.tip.note"), model: model) {
                    model.toggleNote?()
                }
                PillButton(symbol: "macwindow", tip: String(localized: "flow.tip.hub"), model: model) { model.openHub?() }
            }
            .padding(.horizontal, 10)
            .fixedSize()
        case .handsFree:
            HStack(spacing: 9) {
                PillButton(symbol: "xmark", tip: String(localized: "flow.tip.cancel"), model: model, small: true) {
                    model.cancelDictation?()
                }
                bars
                PillButton(symbol: "checkmark", tip: String(format: String(localized: "flow.tip.finish %@"), model.keyLabel),
                           model: model, small: true, filled: true) { model.finishDictation?() }
            }
            .padding(.horizontal, 6)
            .fixedSize()
        default:
            HStack(spacing: 9) {
                mochi
                switch model.phase {
                case .copied, .failed, .pastedAgain:
                    Text(messageText ?? "")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(hex: "#E8E9EC"))
                        .fixedSize()
                case .idle:
                    noteContent
                default:
                    bars
                }
            }
            .padding(.horizontal, 13)
            .fixedSize()
        }
    }

    /// Mochi, drawn by the same engine as the compact island's mini Mochis: his eyes wander all
    /// around while you speak. 22 pt wide like a pill's Mochi (the canvas is larger, as there),
    /// a little larger in the side notch.
    private func mochi(_ width: CGFloat) -> some View {
        // Still while only a recorded call shows: the pill costs nothing during a long call.
        FlowMochiView(active: model.phase != .idle || model.hovered)
            .frame(width: width / 0.6, height: width / 0.6)
            .frame(width: width, height: width, alignment: .center)
    }

    private var mochi: some View { mochi(22) }

    /// A call being recorded: a red dot, the time, and a button to stop.
    @ViewBuilder private var noteContent: some View {
        if let start = model.noteStartedAt {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: "#FF453A"))
                    .frame(width: 8, height: 8)
                    .shadow(color: Color(hex: "#FF453A").opacity(0.6), radius: 3)
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(NoteBuilder.clock(context.date.timeIntervalSince(start)))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(Color(hex: "#E8E9EC"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Button { model.stopNote?() } label: {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .help(String(localized: "notes.stop"))
            }
        }
    }

    /// Nine dots, graves to aigus, across the pill.
    private var bars: some View {
        let active = model.phase == .listening || model.phase == .locked || model.phase == .thinking
        return TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !active)) { context in
            let levels = smoother.frame(at: context.date,
                                        target: model.phase == .thinking ? nil : bands.levels,
                                        thinking: model.phase == .thinking)
            HStack(alignment: .center, spacing: 3.2) {
                ForEach(0..<FlowBands.count, id: \.self) { i in
                    Capsule()
                        .fill(Color.white.opacity(0.94))
                        .frame(width: 3.4, height: 3.4 + 16 * CGFloat(levels[i]))
                }
            }
            .frame(height: 22)
        }
    }

    // MARK: The notch (on the left or right edge)

    /// codenotch's cell grid down the notch: each cell a ring's size, the rings this far apart,
    /// padded from the body's ends by its padTop and padBottom.
    nonisolated static let sideCell: CGFloat = 117 * sidePx
    nonisolated static let sideCellSpacing: CGFloat = 83.5 * sidePx
    nonisolated static let sidePadTop: CGFloat = 69.5 * sidePx
    nonisolated static let sidePadBottom: CGFloat = 50.1 * sidePx
    /// A ring's track and the glyph in it (codenotch's trackStroke and glyphSize).
    nonisolated static let sideTrack: CGFloat = 15.5 * sidePx
    nonisolated static let sideGlyph: CGFloat = 46 * sidePx
    /// codenotch's palette: white ink, and its ring track, brighter under the pointer.
    nonisolated static let inkPrimary = Color.white
    nonisolated static let ringTrack = Color.white.opacity(0.188)
    nonisolated static let ringTrackHover = Color.white.opacity(0.45)
    /// From the notch to the tip of a card's pointer (codenotch's tailGap), less the bleed.
    nonisolated static let sideCardSpacing: CGFloat = FlowSideCardShape.tailGap - sideBleed

    /// How many cells a look stacks.
    static func sideCells(_ look: Look) -> Int {
        switch look {
        case .toolbar:          return 4
        case .note, .handsFree: return 3
        default:                return 2
        }
    }

    /// How long the open notch is for this many cells: flare, padding, the cells, padding and
    /// flare again, as codenotch's shapeLength.
    static func sideLength(cells: Int) -> CGFloat {
        let n = CGFloat(max(1, cells))
        return 2 * sideFlare + sidePadTop + n * sideCell + (n - 1) * sideCellSpacing + sidePadBottom
    }

    /// How far the middle of cell `index` is from the middle of the notch, down the edge.
    static func sideCellOffset(_ index: Int, cells: Int) -> CGFloat {
        sideFlare + sidePadTop + sideCell / 2 + CGFloat(index) * (sideCell + sideCellSpacing)
            - sideLength(cells: cells) / 2
    }

    /// What the notch shows: what it is showing, or while it folds, what it showed open, so the
    /// cells do not change on their way out.
    private var sideLook: Look { look == .resting ? lastOpenLook : look }

    /// Black, flush with the screen's edge and past it, its ends flaring into it. Resting it is a
    /// slim handle; open it grows, on a spring, around Mochi and the rings stacked in it.
    private var sideNotch: some View {
        let left = model.edge == .left
        let depth = open ? Self.sideOpenDepth : Self.sideRestingDepth
        let length = open ? Self.sideLength(cells: Self.sideCells(look)) : Self.sideRestingLength
        let shape = FlowSideNotchShape(left: left)
        return Color.clear
            .frame(width: depth, height: length)
            // Pure black, as codenotch draws it: no hairline.
            .background(shape.fill(Color.black))
            // Hands-free: the orange ring on the inner side (half of it is clipped away).
            .overlay(FlowSideNotchShape(left: left, outlineOnly: true)
                .stroke(Color(hex: "#F97316").opacity(look == .handsFree ? 0.85 : 0), lineWidth: 3))
            // Laid out open, against the screen's edge, so nothing reflows as the notch folds:
            // the outline swallows the cells instead.
            .overlay(alignment: left ? .topLeading : .topTrailing) {
                sideContent
                    .padding(.top, Self.sideFlare + Self.sidePadTop)
                    .frame(width: Self.sideOpenDepth)
                    .allowsHitTesting(open)
            }
            .clipShape(shape)
            .offset(x: left ? -Self.sideBleed : Self.sideBleed)
            .animation(Self.sideSpring, value: look)
            .onChange(of: look) { _, new in if new != .resting { lastOpenLook = new } }
    }

    /// One cell of the grid: a ring's size, centred across the notch, fading in and sliding out
    /// from the edge a beat after the one before it (codenotch's stagger).
    private func cell<V: View>(_ index: Int, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(width: Self.sideCell, height: Self.sideCell)
            .opacity(open ? 1 : 0)
            .offset(x: open ? 0 : (model.edge == .left ? -1 : 1) * 28 * Self.sidePx)
            .animation(Self.sideContentSpring.delay(min(Double(index) * 0.045, 0.18)), value: open)
    }

    @ViewBuilder private var sideContent: some View {
        VStack(spacing: Self.sideCellSpacing) {
            switch sideLook {
            case .toolbar:
                cell(0) { mochi(Self.sideCell) }
                cell(1) {
                    PillButton(symbol: "mic.fill", tip: String(format: String(localized: "flow.tip.dictate %@"), model.keyLabel),
                               model: model, ringed: true, cell: 1) { model.dictate?() }
                }
                cell(2) {
                    PillButton(symbol: "record.circle", tip: String(localized: "flow.tip.note"), model: model,
                               ringed: true, cell: 2) { model.toggleNote?() }
                }
                cell(3) {
                    PillButton(symbol: "macwindow", tip: String(localized: "flow.tip.hub"), model: model,
                               ringed: true, cell: 3) { model.openHub?() }
                }
            case .handsFree:
                cell(0) {
                    PillButton(symbol: "xmark", tip: String(localized: "flow.tip.cancel"), model: model, small: true,
                               ringed: true, cell: 0) { model.cancelDictation?() }
                }
                cell(1) { meter }
                cell(2) {
                    PillButton(symbol: "checkmark", tip: String(format: String(localized: "flow.tip.finish %@"), model.keyLabel),
                               model: model, small: true, filled: true, ringed: true, cell: 2) { model.finishDictation?() }
                }
            case .message:
                cell(0) { mochi(Self.sideCell) }
                cell(1) {
                    Image(systemName: model.phase == .failed ? "mic.slash.fill" : "doc.on.clipboard.fill")
                        .resizable()
                        .scaledToFit()
                        .fontWeight(.semibold)
                        .foregroundColor(Self.inkPrimary)
                        .frame(width: Self.sideGlyph, height: Self.sideGlyph)
                }
            case .note:
                cell(0) { mochi(Self.sideCell) }
                if let start = model.noteStartedAt {
                    // A call being recorded: a red dot over the time, then a ring to stop.
                    cell(1) {
                        VStack(spacing: 6) {
                            Circle()
                                .fill(Color(hex: "#FF453A"))
                                .frame(width: 8, height: 8)
                                .shadow(color: Color(hex: "#FF453A").opacity(0.6), radius: 3)
                            TimelineView(.periodic(from: start, by: 1)) { context in
                                Text(NoteBuilder.clock(context.date.timeIntervalSince(start)))
                                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                    .foregroundColor(Self.inkPrimary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            }
                        }
                    }
                    cell(2) { FlowStopButton { model.stopNote?() } }
                }
            default:
                cell(0) { mochi(Self.sideCell) }
                cell(1) { meter }
            }
        }
        .fixedSize()
    }

    /// Nine bars, graves at the top to aigus at the bottom, each reaching out with the voice,
    /// in one cell.
    private var meter: some View {
        let active = model.phase == .listening || model.phase == .locked || model.phase == .thinking
        return TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !active)) { context in
            let levels = smoother.frame(at: context.date,
                                        target: model.phase == .thinking ? nil : bands.levels,
                                        thinking: model.phase == .thinking)
            VStack(alignment: .center, spacing: 2) {
                ForEach(0..<FlowBands.count, id: \.self) { i in
                    Capsule()
                        .fill(Self.inkPrimary.opacity(0.94))
                        .frame(width: 4 + 36 * CGFloat(levels[i]), height: 3)
                }
            }
            .frame(width: Self.sideCell)
        }
    }
}

/// The notch on a side edge: a pill welded to the screen's edge, with inverse rounded corners at
/// each end that flare back out to the edge, so it reads as part of the bezel rather than a panel.
/// Ported from codenotch's SideNotchShape (MIT, Copyright 2026 Vinz), without what only its
/// hardware notch needs (the cutout, the dip and the joins). Drawn for the right edge, with the
/// screen's edge at `maxX`, and mirrored for the left. The rect is the whole shape, flares
/// included, and runs `bezelHidden` past the screen's edge.
struct FlowSideNotchShape: Shape {
    var left = false
    var flare: CGFloat = FlowPillView.sideFlare
    /// How deep the flare is, when not the same as how far it runs along the edge. Nil keeps it
    /// a quarter circle.
    var flareDepth: CGFloat?
    var cornerRadius: CGFloat = FlowPillView.sideCorner
    /// The band past the screen's edge that nobody sees: kept straight, so each flare starts on
    /// the first row that is on screen and meets the edge flat.
    var bezelHidden: CGFloat = FlowPillView.sideBleed
    /// How much of each flare ramps its bend in and out (see `fluidTurn`).
    var filletRamp: CGFloat = 0.5
    /// Leaves out the line along the screen's edge, for a stroke on the inner side only.
    var outlineOnly = false

    /// The handle reach that makes a cubic trace a circle.
    static let circleReach: CGFloat = 0.5523

    func path(in rect: CGRect) -> Path {
        let depth = rect.width
        let canonical = canonicalPath(in: CGRect(x: 0, y: 0, width: depth, height: rect.height))
        let mirror = left ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: depth, ty: 0) : .identity
        return canonical.applying(mirror).applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    private func canonicalPath(in rect: CGRect) -> Path {
        // Order matters. The corner is claimed first, out of half the width; then the band hidden
        // past the edge; and the flare's depth takes what is left. Left to itself the flare is a
        // quarter circle, so that depth binds its length along the edge too: folded to its pill,
        // the notch is a slim rounded bar with small inverse fillets, not long flares.
        let wanted = max(0, min(cornerRadius, rect.width / 2))
        let bandDepth = max(0, min(bezelHidden, rect.width - wanted))
        let curlDepth = max(0, min(flareDepth ?? flare, rect.width - wanted - bandDepth))
        let curl = flareDepth == nil ? curlDepth : max(0, min(flare, rect.height / 2))
        let corner = max(0, min(wanted, (rect.height - 2 * curl) / 2))
        let bodyTop = rect.minY + curl
        let bodyBottom = rect.maxY - curl
        let hidden = bandDepth
        let far = rect.minX

        var path = Path()
        // Screen edge, above the body.
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        if hidden > 0 { path.addLine(to: CGPoint(x: rect.maxX - hidden, y: rect.minY)) }
        // Flare inward and down onto the top edge.
        if curl > 0.001 {
            fluidTurn(&path, to: CGPoint(x: rect.maxX - hidden - curlDepth, y: bodyTop),
                      leaving: CGVector(dx: 0, dy: 1), arriving: CGVector(dx: -1, dy: 0), ramp: filletRamp)
        }
        path.addLine(to: CGPoint(x: far + corner, y: bodyTop))
        turn(&path, to: CGPoint(x: far, y: bodyTop + corner),
             leaving: CGVector(dx: -1, dy: 0), arriving: CGVector(dx: 0, dy: 1), radius: corner)
        // The far side.
        path.addLine(to: CGPoint(x: far, y: bodyBottom - corner))
        turn(&path, to: CGPoint(x: far + corner, y: bodyBottom),
             leaving: CGVector(dx: 0, dy: 1), arriving: CGVector(dx: 1, dy: 0), radius: corner)
        path.addLine(to: CGPoint(x: rect.maxX - hidden - curlDepth, y: bodyBottom))
        // Flare back out to the screen edge.
        if curl > 0.001 {
            fluidTurn(&path, to: CGPoint(x: rect.maxX - hidden, y: rect.maxY),
                      leaving: CGVector(dx: 1, dy: 0), arriving: CGVector(dx: 0, dy: 1), ramp: filletRamp)
        }
        // Back out across the hidden band.
        if hidden > 0 { path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)) }
        if !outlineOnly { path.closeSubpath() }
        return path
    }

    /// A quarter turn from the current point, leaving along `leaving` and arriving along `arriving`.
    /// Each handle is `circleReach` of the distance the turn covers on its own axis: a circular arc
    /// when the two match, the matching quarter ellipse when they do not.
    private func turn(_ path: inout Path, to: CGPoint, leaving: CGVector, arriving: CGVector, radius: CGFloat) {
        guard radius > 0, let from = path.currentPoint else {
            path.addLine(to: to)
            return
        }
        let out = abs((to.x - from.x) * leaving.dx + (to.y - from.y) * leaving.dy)
        let into = abs((to.x - from.x) * arriving.dx + (to.y - from.y) * arriving.dy)
        guard out > 0, into > 0 else {
            path.addLine(to: to)
            return
        }
        let k = Self.circleReach
        path.addCurve(to: to,
                      control1: CGPoint(x: from.x + leaving.dx * out * k, y: from.y + leaving.dy * out * k),
                      control2: CGPoint(x: to.x - arriving.dx * into * k, y: to.y - arriving.dy * into * k))
    }

    /// A quarter turn whose bend ramps in from nothing at both ends, so the flare meets the screen's
    /// edge without a stiff join. Walked out from its curvature as a fine polyline: `ramp` is the
    /// share of the turn spent ramping at each end, 0 a circular arc, 0.5 no constant bend at all.
    private func fluidTurn(_ path: inout Path, to: CGPoint, leaving: CGVector, arriving: CGVector, ramp: CGFloat) {
        guard let from = path.currentPoint else { return }
        let alongReach = (to.x - from.x) * leaving.dx + (to.y - from.y) * leaving.dy
        let acrossReach = (to.x - from.x) * arriving.dx + (to.y - from.y) * arriving.dy
        guard alongReach != 0, acrossReach != 0 else {
            path.addLine(to: to)
            return
        }
        let p = min(max(ramp, 0), 0.5)
        // Curvature times length, set so the turn comes to exactly a quarter.
        let bend = (CGFloat.pi / 2) / (1 - p)
        let steps = 96
        var heading: CGFloat = 0, u: CGFloat = 0, v: CGFloat = 0
        var walk: [(CGFloat, CGFloat)] = [(0, 0)]
        for i in 0..<steps {
            let s = (CGFloat(i) + 0.5) / CGFloat(steps)
            let share = p <= 0 ? 1 : (s < p ? s / p : (s > 1 - p ? (1 - s) / p : 1))
            heading += bend * share / CGFloat(steps)
            u += cos(heading) / CGFloat(steps)
            v += sin(heading) / CGFloat(steps)
            walk.append((u, v))
        }
        // The walk is symmetric, so one scale per axis lands it on `to`.
        let (endU, endV) = walk[walk.count - 1]
        let alongScale = alongReach / endU, acrossScale = acrossReach / endV
        for (wu, wv) in walk.dropFirst() {
            path.addLine(to: CGPoint(
                x: from.x + leaving.dx * wu * alongScale + arriving.dx * wv * acrossScale,
                y: from.y + leaving.dy * wu * alongScale + arriving.dy * wv * acrossScale))
        }
    }
}

/// A black card beside the side notch with a pointer aiming at it, card and pointer one outline,
/// with codenotch's card measures. The pointer is codenotch's TooltipTail (MIT, Copyright 2026 Vinz).
struct FlowSideCardShape: Shape {
    /// The notch is on the right: the pointer is on the card's right side.
    var pointsRight: Bool

    static let corner: CGFloat = 49.5 * FlowPillView.sidePx
    static let padding: CGFloat = 32 * FlowPillView.sidePx
    static let tailLength: CGFloat = 75 * FlowPillView.sidePx
    static let tailHeight: CGFloat = 87 * FlowPillView.sidePx
    static let tailGap: CGFloat = 28 * FlowPillView.sidePx
    /// A one-line tooltip: its line and the card's padding.
    static let tooltipHeight: CGFloat = 40

    func path(in rect: CGRect) -> Path {
        let l = Self.tailLength
        let card = CGRect(x: pointsRight ? rect.minX : rect.minX + l, y: rect.minY,
                          width: max(0, rect.width - l), height: rect.height)
        let r = min(Self.corner, card.height / 2, card.width / 2)
        let body = Path(roundedRect: card, cornerRadius: r, style: .circular)
        // codenotch's pointer is taller than a short card's straight side: there it keeps its
        // length and narrows to fit, and its base reaches into the card where the corners round
        // off, so the two still meet as one outline.
        let h = min(Self.tailHeight, max(card.height / 2, card.height - 2 * r))
        let over = max(0, h / 2 - (card.height / 2 - r))
        let inset = over > 0 ? r - (r * r - over * over).squareRoot() + 0.5 : 0
        let base = pointsRight ? card.maxX - inset : card.minX + inset
        let tip = pointsRight ? rect.maxX : rect.minX
        let tail = CGRect(x: min(base, tip), y: rect.midY - h / 2, width: abs(tip - base), height: h)
        return body.union(Self.tail(in: tail, pointsRight: pointsRight))
    }

    /// The pointer: its shoulders leave the card along the card's edge, so the two read as one
    /// moulded silhouette, and its point stays crisp.
    static func tail(in rect: CGRect, pointsRight: Bool) -> Path {
        let tip = CGPoint(x: pointsRight ? rect.maxX : rect.minX, y: rect.midY)
        let baseX = pointsRight ? rect.minX : rect.maxX
        let back: CGFloat = pointsRight ? -1 : 1
        var path = Path()
        path.move(to: CGPoint(x: baseX, y: rect.minY))
        path.addCurve(to: tip,
                      control1: CGPoint(x: baseX, y: rect.minY + rect.height * 0.25),
                      control2: CGPoint(x: tip.x + back * rect.width * 0.42, y: rect.midY - rect.height * 0.12))
        path.addCurve(to: CGPoint(x: baseX, y: rect.maxY),
                      control1: CGPoint(x: tip.x + back * rect.width * 0.42, y: rect.midY + rect.height * 0.12),
                      control2: CGPoint(x: baseX, y: rect.maxY - rect.height * 0.25))
        path.closeSubpath()
        return path
    }
}

/// The black card that holds a bubble beside the side notch: pure black, as codenotch's card.
private struct FlowSideCard<Content: View>: View {
    let edge: FlowPillEdge
    let content: Content

    init(edge: FlowPillEdge, @ViewBuilder content: () -> Content) {
        self.edge = edge
        self.content = content()
    }

    var body: some View {
        content
            .padding(edge == .right ? .trailing : .leading, FlowSideCardShape.tailLength)
            .background(FlowSideCardShape(pointsRight: edge == .right).fill(Color.black))
            .fixedSize()
    }
}

/// A round button of the pill, with its bubble above while the pointer is on it. In the side
/// notch it is one of codenotch's rings: a track around the glyph, brighter under the pointer.
private struct PillButton: View {
    let symbol: String
    let tip: String
    @ObservedObject var model: FlowPillModel
    var small = false
    var filled = false
    var ringed = false
    /// Its cell in the side notch, so the bubble can point at it.
    var cell: Int?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            if ringed {
                let glyph = FlowPillView.sideGlyph * (small ? 0.8 : 1)
                ZStack {
                    Circle().fill(filled ? Color.white : Color.white.opacity(hover ? 0.08 : 0))
                    if !filled {
                        Circle().strokeBorder(hover ? FlowPillView.ringTrackHover : FlowPillView.ringTrack,
                                              lineWidth: FlowPillView.sideTrack)
                    }
                    Image(systemName: symbol)
                        .resizable()
                        .scaledToFit()
                        .fontWeight(.semibold)
                        .foregroundColor(filled ? .black : FlowPillView.inkPrimary)
                        .frame(width: glyph, height: glyph)
                }
                .frame(width: FlowPillView.sideCell, height: FlowPillView.sideCell)
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.12), value: hover)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: small ? 10 : 12, weight: .bold))
                    .foregroundColor(filled ? .black : .white)
                    .frame(width: small ? 24 : 28, height: small ? 24 : 28)
                    .background(Circle().fill(filled ? Color.white : Color.white.opacity(hover ? 0.22 : 0.10)))
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tip)
        .onHover { inside in
            // While the pill is carried, no hover and no bubbles.
            hover = inside && !model.dragging
            guard !model.dragging else { return }
            if inside {
                model.tipCell = cell
                model.tooltip = tip
            } else if model.tooltip == tip {
                model.tooltip = nil
            }
        }
    }
}

/// The side notch's button to stop a recorded call: a ring like the others, with its help text.
private struct FlowStopButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.white.opacity(hover ? 0.08 : 0))
                Circle().strokeBorder(hover ? FlowPillView.ringTrackHover : FlowPillView.ringTrack,
                                      lineWidth: FlowPillView.sideTrack)
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(FlowPillView.inkPrimary)
                    .frame(width: 12, height: 12)
            }
            .frame(width: FlowPillView.sideCell, height: FlowPillView.sideCell)
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.12), value: hover)
        }
        .buttonStyle(.plain)
        .help(String(localized: "notes.stop"))
        .onHover { hover = $0 }
    }
}

/// The message above the pill: a symbol, the words, a button to act and one to close. Beside the
/// side notch, in a black card pointing at it.
private struct FlowAnnouncementView: View {
    let announcement: FlowAnnouncement
    let edge: FlowPillEdge
    let act: () -> Void
    let dismiss: () -> Void

    var body: some View {
        if edge == .bottom {
            row
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.95)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                .fixedSize()
        } else {
            // Padded to codenotch's 12 pt card padding, a little more before the symbol.
            FlowSideCard(edge: edge) { row.padding(FlowSideCardShape.padding - 10) }
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            Image(systemName: announcement.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color(hex: announcement.tint))
            Text(announcement.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 270, alignment: .leading)
            if let action = announcement.action {
                Button(action: act) {
                    Text(action)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 13)
                        .frame(height: 28)
                        .background(Capsule().fill(Color(hex: "#F5F1EA")))
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "flow.ann.dismiss"))
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
    }
}

/// The pill's Mochi: a mini Mochi (BotEngine, like the pills of the compact island), white, idle,
/// so his eyes wander around. Drawn only while the pill is open.
private struct FlowMochiView: View {
    let active: Bool
    @StateObject private var engine: BotEngine

    init(active: Bool) {
        self.active = active
        _engine = StateObject(wrappedValue: {
            let e = BotEngine()
            e.isMini = true
            e.bodyColor = cgColorFromHex("#F5F6F8")
            return e
        }())
    }

    var body: some View {
        TimelineView(.animation(paused: !active)) { timeline in
            let frame = timeline.date   // redraw on every tick, as in MiniBotCanvasView
            Canvas { context, size in
                _ = frame
                MochiFrameClock.advance(engine)
                engine.draw(context: context, size: size)
            }
        }
        .onAppear { engine.setState(.idle, force: true) }
    }
}

/// The pill's window: borderless, never takes the focus (the words go to the app you type in), on
/// every Space and over full-screen apps. It stays at the bottom centre of a screen while Flow
/// dictation is on, and moves to the screen the mouse is on when you speak. It is taller than the
/// pill, for the bubbles above it, and lets clicks through except where the pill and its bubble are.
/// On a side edge it touches the screen's very edge, so the notch is welded to it.
@MainActor
final class FlowPillController {
    /// The panel: wide along the bottom (bubbles above the pill), tall on the sides (bubbles beside it).
    static func size(for edge: FlowPillEdge) -> NSSize {
        edge == .bottom ? NSSize(width: 520, height: 170) : NSSize(width: 560, height: 440)
    }

    private var size: NSSize { Self.size(for: model.edge) }

    let model = FlowPillModel()
    private let smoother = FlowLevelSmoother()
    private let bands: FlowAudioBands
    private var panel: NSPanel?
    private var restTask: Task<Void, Never>?
    private var announceTask: Task<Void, Never>?
    private var unhoverTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var mouseMonitors: [Any] = []

    /// Whether Flow dictation is on (the resting pill shows).
    private var dictationOn = false

    init(bands: FlowAudioBands) {
        self.bands = bands
        model.stopNote = { NoteTaker.shared.stop() }
        model.dismissAnnouncement = { [weak self] in self?.dismissAnnouncement() }
    }

    private var shouldShow: Bool { dictationOn || model.noteStartedAt != nil || model.announcement != nil }

    /// The Notetaker records (a date) or stopped (nil): the pill shows it even when dictation is off.
    func setNote(_ start: Date?) {
        model.noteStartedAt = start
        model.noteHours = false
        noteHoursTask?.cancel()
        if let start {
            noteHoursTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0, 3600 - Date().timeIntervalSince(start))))
                guard !Task.isCancelled, let self, self.model.noteStartedAt == start else { return }
                self.model.noteHours = true
            }
        }
        updateVisibility()
    }

    private var noteHoursTask: Task<Void, Never>?

    /// Moves the pill to another edge of the screen.
    func setEdge(_ edge: FlowPillEdge) {
        guard edge != model.edge || panel == nil else { return }
        model.edge = edge
        model.tooltip = nil
        guard let panel else { return }
        panel.setContentSize(size)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        place(panel, onMouseScreen: false)
        updateMouse()
    }

    /// Flow dictation on: the resting pill shows. Off: it goes away.
    func setEnabled(_ on: Bool) {
        restTask?.cancel()
        model.phase = .idle
        dictationOn = on
        updateVisibility()
    }

    private func updateVisibility() {
        if shouldShow {
            if panel == nil { build() }
            guard let panel else { return }
            if !panel.isVisible {
                place(panel, onMouseScreen: false)
                panel.orderFrontRegardless()
            }
            watchMouse()
            if screenObserver == nil {
                screenObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let panel = self.panel, panel.isVisible else { return }
                        self.place(panel, onMouseScreen: false)
                    }
                }
            }
        } else {
            panel?.orderOut(nil)
            stopWatchingMouse()
            model.hovered = false
            model.tooltip = nil
            if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
            screenObserver = nil
        }
    }

    // MARK: - Messages

    /// A message above the pill, with a button to act; it goes away by itself after a while,
    /// unless the pointer is on it.
    func announce(_ announcement: FlowAnnouncement, for seconds: TimeInterval = 8,
                  perform: (@MainActor () -> Void)? = nil) {
        model.tooltip = nil
        model.announcementAction = { [weak self] in
            perform?()
            self?.dismissAnnouncement()
        }
        model.announcement = announcement
        updateVisibility()
        updateMouse()
        announceTask?.cancel()
        announceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            while !Task.isCancelled, self?.model.hovered == true {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            self?.dismissAnnouncement()
        }
    }

    func dismissAnnouncement() {
        announceTask?.cancel()
        model.announcement = nil
        model.announcementAction = nil
        updateVisibility()
        updateMouse()
    }

    // MARK: - The pointer

    /// The panel takes clicks only where the pill and its bubble are; the pill opens under the pointer.
    private func watchMouse() {
        guard mouseMonitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMouse() }
        }) { mouseMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateMouse() }
            return event
        }) { mouseMonitors.append(local) }
        updateMouse()
    }

    private func stopWatchingMouse() {
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors.removeAll()
        panel?.ignoresMouseEvents = true
    }

    /// The parts of the panel that take the pointer, in screen coordinates.
    private func hotRects(_ frame: NSRect) -> [NSRect] {
        let open = model.hovered || model.phase != .idle || model.noteStartedAt != nil
        let bubble = model.announcement != nil || model.tooltip != nil
        switch model.edge {
        case .bottom:
            // The pill: a generous zone around the small resting one, the whole capsule once open.
            let length: CGFloat = open ? 200 : 96
            let thickness: CGFloat = open ? 46 : 26
            var rects = [NSRect(x: frame.midX - length / 2, y: frame.minY, width: length, height: thickness)]
            if model.announcement != nil {
                rects.append(NSRect(x: frame.midX - 240, y: frame.minY + 40, width: 480, height: 110))
            } else if bubble {
                rects.append(NSRect(x: frame.midX - 140, y: frame.minY + 40, width: 280, height: 40))
            }
            return rects
        case .left, .right:
            // The notch, flush with the screen's edge: resting, codenotch's wake zone around the
            // slim one (its length, and its hot zone deep); open, the longest notch, flares included.
            let left = model.edge == .left
            let length: CGFloat = open ? FlowPillView.sideLength(cells: 4) + 8 : 80
            let depth: CGFloat = open ? FlowPillView.sideOpenDepth + 6 : FlowPillView.sideRestingDepth + 90 * FlowPillView.sidePx
            let notchX = left ? frame.minX : frame.maxX - depth
            var rects = [NSRect(x: notchX, y: frame.midY - length / 2, width: depth, height: length)]
            if bubble {
                // The bubble sits right beside the notch, whatever its size; a tooltip is level
                // with its button.
                let card = model.announcement == nil
                let inset: CGFloat = card ? FlowPillView.sideOpenDepth : 14
                let width: CGFloat = card ? 300 : frame.width - inset
                let height: CGFloat = card ? 52 : 150
                let shift = card && model.tooltip != nil
                    ? model.tipCell.map {
                        FlowPillView.sideCellOffset($0, cells: FlowPillView.sideCells(FlowPillView.look(for: model)))
                    } ?? 0
                    : 0
                let x = left ? frame.minX + inset : frame.maxX - inset - width
                rects.append(NSRect(x: x, y: frame.midY - shift - height / 2, width: width, height: height))
            }
            return rects
        }
    }

    private func updateMouse() {
        // Carried, the pill neither opens nor closes under the pointer.
        guard drag == nil, let panel, panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let over = hotRects(panel.frame).contains { NSMouseInRect(mouse, $0, false) }
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
        if over {
            unhoverTask?.cancel()
            unhoverTask = nil
            if !model.hovered { model.hovered = true }
        } else if model.hovered, unhoverTask == nil {
            // A short grace, to move from the pill to its bubble.
            unhoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, self.drag == nil else { return }
                self.unhoverTask = nil
                let mouse = NSEvent.mouseLocation
                if let panel = self.panel, self.hotRects(panel.frame).contains(where: { NSMouseInRect(mouse, $0, false) }) { return }
                self.model.hovered = false
                self.model.tooltip = nil
                self.panel?.ignoresMouseEvents = true
            }
        }
    }

    // MARK: - Dictation

    /// The key is down: open on the screen the mouse is on.
    func listen() {
        restTask?.cancel()
        if panel == nil { build() }
        guard let panel else { return }
        place(panel, onMouseScreen: true)
        panel.orderFrontRegardless()
        smoother.reset()
        model.tooltip = nil
        model.phase = .listening
    }

    /// A short message, then back to rest.
    func flash(_ phase: FlowPillModel.Phase) {
        restTask?.cancel()
        model.phase = phase
        rest(after: 1.8)
    }

    /// Back to the small resting pill.
    func rest(after delay: TimeInterval = 0) {
        restTask?.cancel()
        restTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            self.model.phase = .idle
            self.model.tooltip = nil
            self.updateMouse()
        }
    }

    private func build() {
        let view = NSHostingView(rootView: FlowPillView(model: model, bands: bands, smoother: smoother))
        view.frame = NSRect(origin: .zero, size: size)
        let p = FlowPillPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        // ⌥ and a press on the pill itself (not its bubble) pick it up.
        p.startsDrag = { [weak self] point in
            guard let self, let panel = self.panel, let pill = self.hotRects(panel.frame).first else { return false }
            return NSMouseInRect(point, pill, false)
        }
        p.onDragStart = { [weak self] in self?.beginDrag() }
        p.onDrag = { [weak self] in self?.dragged() }
        p.onDragEnd = { [weak self] in self?.endDrag() }
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = view
        panel = p
    }

    /// At its saved place along its edge, on its screen or the one the mouse is on.
    private func place(_ panel: NSPanel, onMouseScreen: Bool) {
        guard drag == nil else { return }
        stopGlide()
        let mouse = NSEvent.mouseLocation
        let screen = onMouseScreen
            ? (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)
            : (panel.screen ?? NSScreen.main)
        guard let screen else { return }
        panel.setFrameOrigin(origin(Self.middle(on: model.edge, of: screen), on: model.edge, of: screen))
    }

    /// The panel's origin with the pill's middle at `middle` along its edge.
    private func origin(_ middle: CGFloat, on edge: FlowPillEdge, of screen: NSScreen) -> NSPoint {
        let size = Self.size(for: edge)
        switch edge {
        case .bottom:
            // Just above the Dock (or the bottom edge when the Dock hides).
            return NSPoint(x: middle - size.width / 2, y: screen.visibleFrame.minY + 4)
        case .left:
            // Against the screen's very edge, so the notch is welded to it.
            return NSPoint(x: screen.frame.minX, y: middle - size.height / 2)
        case .right:
            return NSPoint(x: screen.frame.maxX - size.width, y: middle - size.height / 2)
        }
    }

    // MARK: - Moving the pill (⌥-drag, as in codenotch)

    /// Let go nearer another edge: that edge is FlowDictation's setting, so the picker in the
    /// Flow settings follows.
    var onMoveToEdge: (@MainActor (FlowPillEdge) -> Void)?
    /// Picked up: a dictation the ⌥ itself just started is dropped.
    var onDragStart: (@MainActor () -> Void)?

    /// The drag under way: its screen, and where the pointer holds the pill (the pointer along
    /// the edge, less the pill's middle).
    private var drag: (screen: NSScreen, grab: CGFloat)?

    /// How much nearer another edge the pointer has to be, let go, for the pill to move onto it
    /// (codenotch's edgeSwitchMargin).
    private static let edgeSwitchMargin: CGFloat = 40

    private static func offsetKey(_ edge: FlowPillEdge) -> String { "flowPillOffset.\(edge.rawValue)" }

    /// Where along its edge the pill sits, 0 to 1 of the room it has there. Centred by default.
    private static func offset(on edge: FlowPillEdge) -> CGFloat {
        guard let saved = UserDefaults.standard.object(forKey: offsetKey(edge)) as? Double else { return 0.5 }
        return CGFloat(min(max(saved, 0), 1))
    }

    /// Where the pill's middle can go along an edge: as far as keeps the whole panel (the pill and
    /// its bubbles) inside the screen's visible frame, so a smaller screen clamps it too.
    private static func track(on edge: FlowPillEdge, of screen: NSScreen) -> ClosedRange<CGFloat> {
        let area = screen.visibleFrame
        let size = size(for: edge)
        let (low, high) = edge == .bottom
            ? (area.minX + size.width / 2, area.maxX - size.width / 2)
            : (area.minY + size.height / 2, area.maxY - size.height / 2)
        return low <= high ? low...high : (low + high) / 2...(low + high) / 2
    }

    private static func middle(on edge: FlowPillEdge, of screen: NSScreen) -> CGFloat {
        let t = track(on: edge, of: screen)
        return t.lowerBound + (t.upperBound - t.lowerBound) * offset(on: edge)
    }

    private static func save(_ middle: CGFloat, on edge: FlowPillEdge, of screen: NSScreen) {
        let t = track(on: edge, of: screen)
        let room = t.upperBound - t.lowerBound
        let f = room > 0 ? (middle - t.lowerBound) / room : 0.5
        UserDefaults.standard.set(Double(min(max(f, 0), 1)), forKey: offsetKey(edge))
    }

    private static func clamp(_ value: CGFloat, to t: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, t.lowerBound), t.upperBound)
    }

    /// A point's place along an edge.
    private static func along(_ point: NSPoint, on edge: FlowPillEdge) -> CGFloat {
        edge == .bottom ? point.x : point.y
    }

    private var panelMiddle: NSPoint {
        guard let frame = panel?.frame else { return .zero }
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    private func beginDrag() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        stopGlide()
        unhoverTask?.cancel()
        unhoverTask = nil
        drag = (screen, Self.along(NSEvent.mouseLocation, on: model.edge) - Self.along(panelMiddle, on: model.edge))
        model.dragging = true
        model.tooltip = nil
        // In the hand: the hand closes on it.
        NSCursor.closedHand.push()
        onDragStart?()
    }

    /// Along its edge with the pointer, never past the room it has there.
    private func dragged() {
        guard let panel, let drag else { return }
        // Again on every step: whatever is under the pointer would otherwise put its own back.
        NSCursor.closedHand.set()
        let middle = Self.clamp(Self.along(NSEvent.mouseLocation, on: model.edge) - drag.grab,
                                to: Self.track(on: model.edge, of: drag.screen))
        panel.setFrameOrigin(origin(middle, on: model.edge, of: drag.screen))
    }

    /// Let go: it stays where it is, or, nearer another edge (never the top, where the island is),
    /// moves onto it, level with the pointer, gliding there along that edge.
    private func endDrag() {
        guard let drag else { return }
        self.drag = nil
        NSCursor.pop()
        model.dragging = false
        let screen = drag.screen, from = model.edge
        let pointer = NSEvent.mouseLocation
        let frame = screen.frame
        let distance: [FlowPillEdge: CGFloat] = [.left: pointer.x - frame.minX,
                                                 .right: frame.maxX - pointer.x,
                                                 .bottom: pointer.y - frame.minY]
        let nearest = FlowPillEdge.allCases.min { distance[$0, default: .infinity] < distance[$1, default: .infinity] } ?? from
        guard nearest != from,
              distance[nearest, default: .infinity] + Self.edgeSwitchMargin < distance[from, default: 0] else {
            Self.save(Self.along(panelMiddle, on: from), on: from, of: screen)
            updateMouse()
            return
        }
        let t = Self.track(on: nearest, of: screen)
        let landing = Self.clamp(Self.along(pointer, on: nearest), to: t)
        // It comes in from where it was: the corner it came round, or level on the other side.
        let start = Self.clamp(Self.along(panelMiddle, on: nearest), to: t)
        Self.save(landing, on: nearest, of: screen)
        if let onMoveToEdge { onMoveToEdge(nearest) } else { setEdge(nearest) }
        glide(from: start, to: landing, on: nearest, of: screen)
    }

    // MARK: - The glide

    private var glideLink: CADisplayLink?
    private var glideTick: FlowDisplayTick?
    private var glideState: (edge: FlowPillEdge, screen: NSScreen, at: CGFloat, to: CGFloat,
                             speed: CGFloat, last: CFTimeInterval?)?

    /// Along `edge` from `start` to `end` on codenotch's settling spring, on the display's own beat.
    /// The link runs only while the pill moves.
    private func glide(from start: CGFloat, to end: CGFloat, on edge: FlowPillEdge, of screen: NSScreen) {
        guard let panel else { return }
        stopGlide()
        panel.setFrameOrigin(origin(start, on: edge, of: screen))
        glideState = (edge, screen, start, end, 0, nil)
        let tick = FlowDisplayTick { [weak self] link in self?.glideStep(link) }
        let link = screen.displayLink(target: tick, selector: #selector(FlowDisplayTick.tick(_:)))
        link.add(to: .main, forMode: .common)
        glideLink = link
        glideTick = tick
    }

    private func glideStep(_ link: CADisplayLink) {
        guard let panel, var g = glideState else { return stopGlide() }
        let elapsed = CGFloat(min(max(link.timestamp - (g.last ?? link.timestamp - link.duration), 0), 1.0 / 30))
        g.last = link.timestamp
        let gap = g.to - g.at
        if abs(gap) < 0.3, abs(g.speed) < 6 {
            panel.setFrameOrigin(origin(g.to, on: g.edge, of: g.screen))
            stopGlide()
            updateMouse()
            return
        }
        let (moved, speed) = Self.spring(gap: gap, velocity: g.speed, elapsed: elapsed)
        g.at += moved
        g.speed = speed
        glideState = g
        panel.setFrameOrigin(origin(g.at, on: g.edge, of: g.screen))
    }

    private func stopGlide() {
        glideLink?.invalidate()
        glideLink = nil
        glideTick = nil
        glideState = nil
    }

    /// One frame of a spring toward a target `gap` away: how far it moves, and its speed after.
    /// Two half steps, which keeps it steady at a slow frame. codenotch's (MIT, Copyright 2026 Vinz),
    /// with its settling response and damping.
    private static func spring(gap: CGFloat, velocity: CGFloat, elapsed: CGFloat,
                               response: CGFloat = 0.3, damping: CGFloat = 0.74) -> (CGFloat, CGFloat) {
        let omega = 2 * .pi / response
        var moved: CGFloat = 0, velocity = velocity
        for _ in 0..<2 {
            let dt = elapsed / 2
            let acceleration = omega * omega * (gap - moved) - 2 * damping * omega * velocity
            velocity += acceleration * dt
            moved += velocity * dt
        }
        return (moved, velocity)
    }
}

/// The pill's panel. A press with ⌥ held on the pill picks it up, as in codenotch (MIT, Copyright
/// 2026 Vinz); every other press goes to the pill's buttons as before. The panel takes the pointer
/// only while it is over the pill or its bubble (see `updateMouse`), so a press anywhere else,
/// with ⌥ or not, still goes to the app under it.
private final class FlowPillPanel: NSPanel {
    /// Whether a press at this point, in screen coordinates, is on the pill.
    var startsDrag: (@MainActor (NSPoint) -> Bool)?
    var onDragStart: (@MainActor () -> Void)?
    var onDrag: (@MainActor () -> Void)?
    var onDragEnd: (@MainActor () -> Void)?

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown, event.modifierFlags.contains(.option),
              startsDrag?(convertPoint(toScreen: event.locationInWindow)) == true
        else { return super.sendEvent(event) }
        onDragStart?()
        // This window's own events until the button comes up, the usual AppKit way to follow a
        // drag started from a press. It never turns into a click.
        while let next = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            onDrag?()
        }
        onDragEnd?()
    }
}

/// Calls back on each frame of a display link, which needs an Objective-C target.
@MainActor
private final class FlowDisplayTick: NSObject {
    private let action: @MainActor (CADisplayLink) -> Void

    init(_ action: @escaping @MainActor (CADisplayLink) -> Void) {
        self.action = action
    }

    @objc func tick(_ link: CADisplayLink) { action(link) }
}
#endif
