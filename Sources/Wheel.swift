// The Shift-drag wheel and the little progress windows jobs run in.
//
// Polls the mouse button, modifier keys and drag pasteboard (cheap reads, no permission needed;
// global event monitors don't reliably see another app's drag session). While a file drag is under
// way, holding Shift opens a wheel of output formats around the pointer; Option+Shift fills it with
// tools for that kind of file. Dropping on a petal runs the job beside the original.

import SwiftUI
import AppKit
import QuickLookThumbnailing

enum PetalAction { case convert(Format), op(Op), copy, more }

extension NSScreen {
    static var underPointer: NSScreen {
        screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? main!
    }
}

struct Petal: Identifiable {
    let id: String
    let title: String
    let symbol: String?
    let action: PetalAction
}

@MainActor
final class Shelf: ObservableObject {
    static let shared = Shelf()
    enum Mode { case convert, tools }

    static let diameter: CGFloat = 400
    static let panelSize = NSSize(width: 440, height: 464)

    /// What's being dragged. Setting it works out the kind and tools once, rather than on every redraw.
    @Published var urls: [URL] = [] {
        didSet {
            let kinds = Set(urls.map(Kind.of))
            kind = kinds.count == 1 ? kinds.first : nil
            tools = Op.available(for: kind, count: urls.count)
            petals = makePetals()
        }
    }
    @Published var mode: Mode = .convert { didSet { if mode != oldValue { petals = makePetals() } } }
    private(set) var kind: Kind?
    private(set) var tools: [Op] = []
    @Published private(set) var petals: [Petal] = []
    @Published var hovered: Int?
    @Published var thumbnail: NSImage?
    @Published var sizeLabel = ""
    @Published var showID = 0
    @Published var enabled = UserDefaults.standard.object(forKey: "shelfEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "shelfEnabled") }
    }

    private var panel: NSPanel!
    private var changeCountAtMouseDown = 0
    private var buttonDown = false
    private var emptyDragCount = -1
    /// Opened by a click (Elxplorer), not a drag: keep the mode it opened in; the next click picks or dismisses.
    private var clickMode = false   // a drag pasteboard already found to hold no files
    private var hideTask: Task<Void, Never>?
    private var measureTask: Task<Void, Never>?

    /// Total size of what's being dragged, folders included; big folders fill in a moment later.
    private func measure(_ urls: [URL]) {
        sizeLabel = "…"
        measureTask?.cancel()
        measureTask = Task.detached(priority: .userInitiated) {
            let total = urls.reduce(Int64(0)) { $0 + SizeItem.measure($1).bytes }
            guard !Task.isCancelled else { return }
            await MainActor.run { Shelf.shared.sizeLabel = bytes(total) }
        }
    }

    private static let extensionAliases = ["jpeg": "jpg", "tif": "tiff", "aif": "aiff", "htm": "html"]

    private func archivePetal(_ id: String) -> Petal {
        let f = Formats.archiveOut.first { $0.id == id }!
        return Petal(id: id, title: Formats.short(f), symbol: "archivebox", action: .convert(f))
    }

    private func makePetals() -> [Petal] {
        let more = Petal(id: "more", title: "More", symbol: "ellipsis.circle", action: .more)
        let copy = Petal(id: "copy", title: "Copy", symbol: "doc.on.doc", action: .copy)
        if mode == .tools, !tools.isEmpty {
            var items = tools.map { Petal(id: $0.rawValue, title: $0.title, symbol: $0.symbol, action: .op($0)) }
            if items.count < 4 { items += ["zip", "7z"].map(archivePetal) }   // a near-empty wheel: offer zipping too
            return items + [copy, more]
        }
        // Skip "convert to what it already is" (re-encodes like HEVC or 16-bit TIFF have their own ids, so they stay).
        let exts = Set(urls.map { Self.extensionAliases[$0.pathExtension.lowercased()] ?? $0.pathExtension.lowercased() })
        let formats = (kind.map(Formats.shelf(for:)) ?? []).filter { !(exts == [$0.ext] && $0.id == $0.ext) }
        var items = formats.map {
            Petal(id: $0.id, title: Formats.short($0), symbol: $0.id == "extract" ? "archivebox" : nil, action: .convert($0))
        }
        let archives = kind == .archive ? ["zip", "7z"] : items.isEmpty ? ["zip", "7z", "tgz", "txz"] : ["zip"]
        items += archives.map(archivePetal)
        return items + [copy, more]
    }

    func start() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: ShelfRoot())

        let drag = NSPasteboard(name: .drag)
        let timer = Timer(timeInterval: 1.0 / 25, repeats: true) { _ in
            MainActor.assumeIsolated { Shelf.shared.poll(drag) }
        }
        timer.tolerance = 0.01   // lets macOS batch the wakeups
        RunLoop.main.add(timer, forMode: .common)
    }

    private func poll(_ drag: NSPasteboard) {
        guard enabled else { return }
        let down = NSEvent.pressedMouseButtons & 1 != 0
        if down && !buttonDown {
            // A drag that starts during this press will bump the drag pasteboard past this count.
            changeCountAtMouseDown = drag.changeCount
        } else if !down && buttonDown && panel.isVisible {
            // A drop on the wheel arrives just after mouse-up; give it a moment before closing.
            hideTask?.cancel()
            hideTask = Task { try? await Task.sleep(for: .milliseconds(300)); if !Task.isCancelled { hide() } }
        }
        buttonDown = down
        if down { dragged(drag) }
    }

    private func dragged(_ drag: NSPasteboard) {
        let flags = NSEvent.modifierFlags
        if panel.isVisible {
            if clickMode { return }
            // Option can be pressed or released mid-drag to flip between formats and tools.
            let wanted: Mode = flags.contains(.option) ? .tools : .convert
            if wanted != mode { mode = wanted; hovered = nil }
            return
        }
        guard flags.contains(.shift), drag.changeCount != changeCountAtMouseDown, drag.changeCount != emptyDragCount else { return }
        let urls = drag.fileURLs
        guard !urls.isEmpty else {
            emptyDragCount = drag.changeCount   // dragging text or such: don't re-read it 25 times a second
            return
        }
        self.urls = urls
        mode = flags.contains(.option) ? .tools : .convert
        hovered = nil
        showID += 1
        measure(urls)
        loadThumbnail(urls[0])
        show()
    }

    private func loadThumbnail(_ url: URL) {
        thumbnail = NSWorkspace.shared.icon(forFile: url.path)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 168, height: 168),
                                                   scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async { if Shelf.shared.urls.first == url { Shelf.shared.thumbnail = image } }
        }
    }

    /// Opens the wheel at a point for files that aren't being dragged (Elxplorer's ⌥-right-click):
    /// petals are then clicked instead of dropped on.
    func showWheel(for urls: [URL], at point: NSPoint, tools: Bool) {
        guard !urls.isEmpty else { return }
        self.urls = urls
        clickMode = true
        mode = tools ? .tools : .convert
        hovered = nil
        showID += 1
        measure(urls)
        loadThumbnail(urls[0])
        show(at: point)
    }

    /// A click on the wheel (rather than a drop): run the petal under the pointer.
    func click(_ index: Int?) {
        guard let index, index < petals.count else { return }
        perform(petals[index].action, urls: urls)
    }

    private func show(at point: NSPoint? = nil) {
        hideTask?.cancel()
        let size = Self.panelSize
        let mouse = point ?? NSEvent.mouseLocation
        let screen = NSScreen.underPointer
        let visible = screen.visibleFrame
        // Centre the wheel (not the whole panel, which has a caption below) on the pointer.
        let wheelCentreFromTop = 10 + Self.diameter / 2
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - (size.height - wheelCentreFromTop))
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    func hide() {
        clickMode = false
        hideTask?.cancel()
        measureTask?.cancel()
        panel.orderOut(nil)
        hovered = nil
    }

    func perform(_ action: PetalAction, urls: [URL]) {
        hide()
        guard !urls.isEmpty else { return }
        switch action {
        case .copy:
            // Same as ⌘C in Finder: paste the files anywhere with ⌘V.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
            JobHUD.notice(urls.count == 1 ? "Copied \(urls[0].lastPathComponent)" : "Copied \(urls.count) items",
                          "Paste them anywhere with ⌘V.")
        case .more:
            Store.shared.add(urls)
            (NSApp.delegate as? AppDelegate)?.showMainWindow()
        case .convert(let format):
            runConvert(format, urls)
        case .op(.info):
            Editors.openInfo(urls)
        case .op(.batchRename):
            Editors.openBatchRename(urls)
        case .op(.removeBackground) where urls.contains(where: { Kind.of($0) == .video }):
            guard let background = askVideoBackground() else { return }
            Task { await Ops.run(.removeBackground, urls, hud: JobHUD(title: "Removing background", total: urls.count), background: background) }
        case .op(.fitSize):
            guard let target = askTargetSize(urls) else { return }
            Task { await Ops.run(.fitSize, urls, hud: JobHUD(title: "Fitting to \(bytes(target))", total: urls.count), target: target) }
        case .op(let op):
            if op.interactive { urls.prefix(6).forEach { Editors.open(op, $0) } }
            else { Task { await Ops.run(op, urls, hud: JobHUD(title: op.title, total: op.combines ? 1 : urls.count)) } }
        }
    }

    /// A small menu at the pointer: what should replace a video's background?
    private func askVideoBackground() -> VideoBackground? {
        NSApp.activate(ignoringOtherApps: true)
        let picker = MenuPicker()
        let menu = NSMenu()
        menu.addItem(withTitle: "Replace the background with:", action: nil, keyEquivalent: "").isEnabled = false
        for (i, option) in VideoBackground.allCases.enumerated() {
            let item = NSMenuItem(title: option.rawValue, action: #selector(MenuPicker.pick(_:)), keyEquivalent: "")
            item.tag = i
            item.target = picker
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)   // returns once the menu closes
        return picker.chosen.map { VideoBackground.allCases[$0] }
    }

    final class MenuPicker: NSObject {
        var chosen: Int?
        @objc func pick(_ item: NSMenuItem) { chosen = item.tag }
    }

    private func askTargetSize(_ urls: [URL]) -> Int64? {
        NSApp.activate(ignoringOtherApps: true)
        let current = urls.map { Int64(Ops.fileSize($0)) }.max() ?? 0
        let alert = NSAlert()
        alert.messageText = "Fit to what size?"
        alert.informativeText = "Each file is shrunk to at most this size. Examples: 2 MB, 500 KB, 1.5 GB."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = bytes(max(current / 2, 100_000))
        alert.accessoryView = field
        alert.addButton(withTitle: "Shrink")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Ops.parseSize(field.stringValue)
    }

    private func runConvert(_ format: Format, _ urls: [URL]) {
        let combine = Formats.archiveIDs.contains(format.id) && urls.count > 1 && !urls.allSatisfy { Kind.of($0) == .archive }
        let verb = format.id == "extract" ? "Extracting" : combine ? "Compressing" : "Converting"
        let hud = JobHUD(title: format.id == "extract" ? verb : "\(verb) to \(Formats.short(format))",
                         total: combine ? 1 : urls.count)
        let options = Store.shared.options
        Task {
            var outs: [URL] = [], errors: [String] = []
            if combine {
                hud.current = "\(urls.count) items"
                do { outs.append(try await Converter.compress(urls, as: format, options: options)) }
                catch { errors.append(error.localizedDescription) }
                hud.done = 1
            } else {
                for url in urls {
                    hud.current = url.lastPathComponent
                    let name = url.lastPathComponent
                    let report: @Sendable (String) -> Void = { step in Task { @MainActor in hud.current = "\(name) · \(step)" } }
                    do { outs.append(try await Converter.$report.withValue(report) { try await Converter.convert(url, to: format, options: options) }) }
                    catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                    hud.done += 1
                }
            }
            hud.finish(outs: outs, errors: errors)
        }
    }
}

// MARK: Wheel views

struct ShelfRoot: View {
    @ObservedObject var shelf = Shelf.shared
    var body: some View { WheelView().id(shelf.showID) }   // fresh view (and pop-in) on every show
}

struct WheelView: View {
    @ObservedObject var shelf = Shelf.shared
    @StateObject private var appeared = Flag()
    @Environment(\.colorScheme) private var scheme
    var animated = true
    var glass = true    // off only when rendering to an image, which can't draw the native blur

    let size = Shelf.diameter
    let outer: CGFloat = Shelf.diameter / 2 - 6
    let inner: CGFloat = 84

    var body: some View {
        let petals = shelf.petals
        let dark = scheme == .dark
        VStack(spacing: 12) {
            ZStack {
                if glass { GlassDisc(diameter: size) } else { Circle().fill(Color(white: dark ? 0.2 : 0.86)) }
                Circle().fill(Color.white.opacity(dark ? 0.04 : 0.25))
                Circle().strokeBorder(Color.white.opacity(dark ? 0.25 : 0.7), lineWidth: 1)
                ForEach(Array(petals.enumerated()), id: \.element.id) { i, petal in
                    PetalView(petal: petal, index: i, count: petals.count, hovered: shelf.hovered == i,
                              inner: inner, outer: outer - 4, size: size, dark: dark)
                        .equatable()
                }
                hub(dark: dark)
            }
            .frame(width: size, height: size)
            .modifier(DropTarget(enabled: glass, delegate: WheelDrop(shelf: shelf, size: size, inner: inner, outer: outer, count: petals.count)))
            // Opened by a click (from Elxplorer), the petals are chosen by pointing and clicking.
            .onContinuousHover { phase in
                if case .active(let point) = phase {
                    let i = WheelDrop(shelf: shelf, size: size, inner: inner, outer: outer, count: petals.count).index(at: point)
                    if shelf.hovered != i { shelf.hovered = i }
                } else if shelf.hovered != nil {
                    shelf.hovered = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { point in
                shelf.click(WheelDrop(shelf: shelf, size: size, inner: inner, outer: outer, count: petals.count).index(at: point))
            }

            Text(caption)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
        }
        .padding(.top, 10)
        .frame(width: Shelf.panelSize.width, height: Shelf.panelSize.height, alignment: .top)
        .scaleEffect(appeared.on || !animated ? 1 : 0.82)
        .opacity(appeared.on || !animated ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { appeared.on = true } }
        .animation(.easeOut(duration: 0.15), value: shelf.mode)
    }

    var caption: String {
        switch shelf.mode {
        case .convert: return shelf.tools.isEmpty ? "Drop on a format" : "Hold ⌥ for tools"
        case .tools: return shelf.tools.isEmpty ? "No tools for this file type" : "Release ⌥ for formats"
        }
    }

    func hub(dark: Bool) -> some View {
        ZStack {
            Circle().fill(Color.white.opacity(dark ? 0.1 : 0.5)).frame(width: inner * 2 - 16, height: inner * 2 - 16)
            if let thumb = shelf.thumbnail {
                Image(nsImage: thumb).resizable().scaledToFit()
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            }
            Text(shelf.sizeLabel)
                .font(.system(size: 12, weight: .bold))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(.thickMaterial, in: Capsule())
                .offset(y: 30)
            if shelf.urls.count > 1 {
                Text("\(shelf.urls.count)")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Circle().fill(accent))
                    .offset(x: 38, y: -38)
            }
        }
    }
}

/// The wheel's drop target, left off when rendering to an image (it would draw as a placeholder box).
struct DropTarget: ViewModifier {
    let enabled: Bool
    let delegate: WheelDrop
    func body(content: Content) -> some View {
        if enabled { content.onDrop(of: [.fileURL], delegate: delegate) } else { content }
    }
}

/// Equatable so a hover change redraws only the two petals it affects, not the whole ring.
struct PetalView: View, Equatable {
    static func == (a: PetalView, b: PetalView) -> Bool {
        a.petal.id == b.petal.id && a.petal.title == b.petal.title && a.index == b.index && a.count == b.count
            && a.hovered == b.hovered && a.dark == b.dark && a.inner == b.inner && a.outer == b.outer
    }

    let petal: Petal
    let index: Int
    let count: Int
    let hovered: Bool
    let inner: CGFloat
    let outer: CGFloat
    let size: CGFloat
    let dark: Bool

    var body: some View {
        let span = 360.0 / Double(count)
        let start = Double(index) * span - span / 2   // first petal sits at 12 o'clock
        let shape = PetalShape(start: start, end: start + span, inner: inner, outer: outer, gap: 7, corner: 12)
        let mid = (inner + outer) / 2
        let angle = (start + span / 2) * .pi / 180
        ZStack {
            shape.fill(fill).opacity(hovered ? 1 : (dark ? 0.16 : 0.62))
            shape.stroke(Color.white.opacity(hovered ? 0 : (dark ? 0.18 : 0.8)), lineWidth: 1)
            label
                .frame(width: min(84, 2 * mid * sin(span * .pi / 360) - 8))
                .position(x: size / 2 + mid * sin(angle), y: size / 2 - mid * cos(angle))
        }
        .frame(width: size, height: size)
        .scaleEffect(hovered ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    var fill: AnyShapeStyle {
        hovered ? AnyShapeStyle(LinearGradient(colors: [Color(red: 1, green: 0.5, blue: 0.2), Color(red: 0.93, green: 0.33, blue: 0.12)],
                                               startPoint: .top, endPoint: .bottom))
                : AnyShapeStyle(Color.white)
    }

    var label: some View {
        VStack(spacing: 4) {
            if let symbol = petal.symbol { Image(systemName: symbol).font(.system(size: 16, weight: .semibold)) }
            Text(petal.title.uppercased())
                .font(.system(size: petal.symbol == nil ? (count > 7 ? 15 : 17) : 9.5, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(hovered ? Color.white : (dark ? Color.white.opacity(0.92) : Color(white: 0.24)))
    }
}

/// An annular sector with rounded corners, separated from its neighbours by `gap`.
struct PetalShape: Shape {
    let start: Double, end: Double     // degrees, 0 = up, clockwise
    let inner: CGFloat, outer: CGFloat
    let gap: CGFloat, corner: CGFloat

    func path(in rect: CGRect) -> Path {
        let o = CGPoint(x: rect.midX, y: rect.midY)
        let half = gap / 2
        func out(_ a: CGFloat) -> CGPoint { CGPoint(x: sin(a), y: -cos(a)) }   // radial, pointing outward
        func cw(_ a: CGFloat) -> CGPoint { CGPoint(x: cos(a), y: sin(a)) }      // tangential, clockwise
        func at(_ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: o.x + r * sin(a), y: o.y - r * cos(a)) }

        // Where a side (the radial line at `a`, pushed `half` into the petal) meets the circle of radius `r`,
        // rounded by a small circle tangent to both. `into` is +1 for the start side, -1 for the end side.
        func roundCorner(_ a: CGFloat, into: CGFloat, _ r: CGFloat, outerEdge: Bool) -> (centre: CGPoint, onCircle: CGPoint, onSide: CGPoint) {
            let cr = outerEdge ? r - corner : r + corner
            let ca = a + asin((half + corner) / cr) * into
            let centre = at(cr, ca)
            let rel = CGPoint(x: centre.x - o.x, y: centre.y - o.y)
            let along = rel.x * out(a).x + rel.y * out(a).y
            let onSide = CGPoint(x: o.x + out(a).x * along + cw(a).x * half * into,
                                 y: o.y + out(a).y * along + cw(a).y * half * into)
            return (centre, at(r, ca), onSide)
        }

        func arc(_ p: inout Path, centre: CGPoint, radius: CGFloat, to b: CGPoint, steps: Int = 10) {
            let a = p.currentPoint!
            let a1 = atan2(a.y - centre.y, a.x - centre.x)
            var d = atan2(b.y - centre.y, b.x - centre.x) - a1
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            for i in 1...steps {
                let t = a1 + d * CGFloat(i) / CGFloat(steps)
                p.addLine(to: CGPoint(x: centre.x + radius * cos(t), y: centre.y + radius * sin(t)))
            }
        }

        let s = CGFloat(start * .pi / 180), e = CGFloat(end * .pi / 180)
        let so = roundCorner(s, into: 1, outer, outerEdge: true)
        let eo = roundCorner(e, into: -1, outer, outerEdge: true)
        let ei = roundCorner(e, into: -1, inner, outerEdge: false)
        let si = roundCorner(s, into: 1, inner, outerEdge: false)

        var p = Path()
        p.move(to: so.onCircle)
        arc(&p, centre: o, radius: outer, to: eo.onCircle, steps: 40)
        arc(&p, centre: eo.centre, radius: corner, to: eo.onSide)
        p.addLine(to: ei.onSide)
        arc(&p, centre: ei.centre, radius: corner, to: ei.onCircle)
        arc(&p, centre: o, radius: inner, to: si.onCircle, steps: 24)
        arc(&p, centre: si.centre, radius: corner, to: si.onSide)
        p.addLine(to: so.onSide)
        arc(&p, centre: so.centre, radius: corner, to: so.onCircle)
        p.closeSubpath()
        return p
    }
}

/// Real behind-window blur, masked to a circle.
struct GlassDisc: NSViewRepresentable {
    let diameter: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// One drop target for the whole wheel; the petal is worked out from the pointer's angle.
struct WheelDrop: DropDelegate {
    let shelf: Shelf
    let size: CGFloat
    let inner: CGFloat
    let outer: CGFloat
    let count: Int

    func index(at p: CGPoint) -> Int? {
        let dx = p.x - size / 2, dy = p.y - size / 2
        let r = hypot(dx, dy)
        guard count > 0, r > inner, r < outer + 10 else { return nil }
        let span = 360 / Double(count)
        var deg = (atan2(dx, -dy) * 180 / .pi + span / 2).truncatingRemainder(dividingBy: 360)
        if deg < 0 { deg += 360 }
        return min(Int(deg / span), count - 1)
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let i = index(at: info.location)
        if shelf.hovered != i { shelf.hovered = i }
        return DropProposal(operation: i == nil ? .forbidden : .copy)
    }

    func dropExited(info: DropInfo) { shelf.hovered = nil }

    func performDrop(info: DropInfo) -> Bool {
        guard let i = index(at: info.location) else { return false }
        let action = shelf.petals[i].action
        loadURLs(info.itemProviders(for: [.fileURL])) { shelf.perform(action, urls: $0) }
        return true
    }
}

// MARK: - Progress window

@MainActor
final class JobHUD: ObservableObject {
    @Published var title: String
    @Published var current = ""
    @Published var done = 0
    let total: Int
    @Published var outs: [URL] = []
    @Published var errors: [String] = []
    @Published var note: String?
    @Published var finished = false

    private var panel: NSPanel!
    private static var open: [JobHUD] = []

    init(title: String, total: Int) {
        self.title = title
        self.total = max(total, 1)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 100),
                        styleMask: [.titled, .closable, .utilityWindow, .hudWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.title = "Elconvo"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: JobHUDView(hud: self))

        // Stack in the top-right corner of the screen the pointer is on.
        let screen = NSScreen.underPointer
        let v = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(x: v.maxX - 360, y: v.maxY - 16 - CGFloat(Self.open.count) * 140))
        Self.open.append(self)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Self.open.removeAll { $0 === self } }
        }
        panel.orderFrontRegardless()
    }

    func finish(outs: [URL], errors: [String], note: String? = nil) {
        self.outs = outs
        self.errors = errors
        self.note = note
        done = total
        finished = true
        NSSound(named: errors.isEmpty ? "Glass" : "Basso")?.play()
        Ops.delivered(outs)
        if errors.isEmpty && note == nil {
            Task { try? await Task.sleep(for: .seconds(3)); close() }
        }
    }

    func close() { panel.close() }

    /// A finished-looking HUD with just a message, which closes itself.
    static func notice(_ title: String, _ message: String) {
        let hud = JobHUD(title: title, total: 1)
        hud.note = message
        hud.done = 1
        hud.finished = true
        Task { try? await Task.sleep(for: .seconds(7)); hud.close() }
    }
}

struct JobHUDView: View {
    @ObservedObject var hud: JobHUD

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(color)
                Text(hud.title).font(.headline).lineLimit(1)
                Spacer()
                if hud.total > 1 { Text("\(hud.done)/\(hud.total)").monospacedDigit().foregroundStyle(.secondary) }
            }
            if !hud.finished {
                ProgressView(value: Double(hud.done), total: Double(hud.total)).tint(accent)
                Text(hud.current).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else {
                if let note = hud.note {
                    Text(note).font(.callout).textSelection(.enabled).lineLimit(8).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(hud.errors.prefix(4), id: \.self) { error in
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if !hud.outs.isEmpty {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(hud.outs) }
                    }
                    Spacer()
                    Button("Done") { hud.close() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    var icon: String {
        !hud.finished ? "arrow.triangle.2.circlepath"
            : !hud.errors.isEmpty ? "exclamationmark.triangle.fill"
            : hud.outs.isEmpty && hud.note != nil ? "info.circle.fill" : "checkmark.circle.fill"
    }
    var color: Color {
        !hud.finished ? accent : !hud.errors.isEmpty ? .red : hud.outs.isEmpty && hud.note != nil ? accent : .green
    }
}
