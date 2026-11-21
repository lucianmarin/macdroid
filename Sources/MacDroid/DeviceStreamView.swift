import AppKit
import AVFoundation
import SwiftUI

struct DeviceStreamView: NSViewRepresentable {
    let session: ScrcpySession

    func makeNSView(context: Context) -> StreamNSView {
        let view = StreamNSView(session: session)
        session.onSampleBuffer = { [weak view] buffer in
            view?.enqueue(buffer)
        }
        return view
    }

    func updateNSView(_ nsView: StreamNSView, context: Context) {
        nsView.session = session
    }
}

final class StreamNSView: NSView {
    var session: ScrcpySession
    private let displayLayer = AVSampleBufferDisplayLayer()

    init(session: ScrcpySession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer = displayLayer
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }

    private func devicePoint(from event: NSEvent) -> (Int32, Int32)? {
        let loc = convert(event.locationInWindow, from: nil)
        let videoSize = session.videoSize
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return nil
        }

        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let renderedWidth = videoSize.width * scale
        let renderedHeight = videoSize.height * scale
        let offsetX = (bounds.width - renderedWidth) / 2
        let offsetY = (bounds.height - renderedHeight) / 2

        let normX = (loc.x - offsetX) / renderedWidth
        // AppKit origin is bottom-left; Android origin is top-left.
        let normY = 1.0 - (loc.y - offsetY) / renderedHeight

        guard (0...1).contains(normX), (0...1).contains(normY) else { return nil }
        let x = Int32((normX * videoSize.width).rounded())
        let y = Int32((normY * videoSize.height).rounded())
        return (x, y)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let (x, y) = devicePoint(from: event) else { return }
        session.sendTouch(action: .down, x: x, y: y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let (x, y) = devicePoint(from: event) else { return }
        session.sendTouch(action: .move, x: x, y: y)
    }

    override func mouseUp(with event: NSEvent) {
        guard let (x, y) = devicePoint(from: event) else { return }
        session.sendTouch(action: .up, x: x, y: y)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let (x, y) = devicePoint(from: event) else { return }
        let h = Int16(clamping: Int(event.scrollingDeltaX * 128))
        let v = Int16(clamping: Int(event.scrollingDeltaY * 128))
        session.sendScroll(x: x, y: y, hScroll: h, vScroll: v)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else {
            return false
        }
        session.pushDroppedFiles(urls)
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command), let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "v":
                session.pasteFromMacClipboard()
                return true
            case "c", "x", "a", "z":
                if let keycode = Self.letterKeyCode(chars) {
                    var meta: AndroidMetaState = [.ctrlOn, .ctrlLeftOn]
                    if mods.contains(.shift) { meta.insert([.shiftOn, .shiftLeftOn]) }
                    session.sendKeyEvent(action: .down, keycode: keycode, metaState: meta)
                    session.sendKeyEvent(action: .up, keycode: keycode, metaState: meta)
                    return true
                }
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let meta = Self.androidMetaState(from: mods)

        // Special / navigation keys
        if let special = Self.specialKeyCode(event.keyCode) {
            session.sendKeyTap(special, metaState: meta)
            return
        }

        // Ctrl / Alt / Cmd shortcuts -> forward as Android keycode + metaState
        if mods.contains(.control) || mods.contains(.option) || mods.contains(.command) {
            if let chars = event.charactersIgnoringModifiers?.lowercased(),
               let keycode = Self.letterKeyCode(chars) {
                session.sendKeyEvent(action: .down, keycode: keycode, metaState: meta)
                session.sendKeyEvent(action: .up, keycode: keycode, metaState: meta)
                return
            }
        }

        if let chars = event.characters, !chars.isEmpty {
            session.sendText(chars)
        }
    }

    private static func androidMetaState(from flags: NSEvent.ModifierFlags) -> AndroidMetaState {
        var meta: AndroidMetaState = []
        if flags.contains(.shift) { meta.insert([.shiftOn, .shiftLeftOn]) }
        if flags.contains(.option) { meta.insert([.altOn, .altLeftOn]) }
        if flags.contains(.control) { meta.insert([.ctrlOn, .ctrlLeftOn]) }
        if flags.contains(.command) { meta.insert([.metaOn, .metaLeftOn]) }
        return meta
    }

    private static func specialKeyCode(_ macKeyCode: UInt16) -> AndroidKeyCode? {
        switch macKeyCode {
        case 51: return .del           // Backspace
        case 117: return .forwardDel   // Forward Delete
        case 36, 76: return .enter     // Return / Numpad Enter
        case 48: return .tab           // Tab
        case 53: return .escape        // Escape
        case 123: return .dpadLeft
        case 124: return .dpadRight
        case 125: return .dpadDown
        case 126: return .dpadUp
        case 115: return .moveHome
        case 119: return .moveEnd
        case 116: return .pageUp
        case 121: return .pageDown
        default: return nil
        }
    }

    private static func letterKeyCode(_ char: String) -> UInt32? {
        guard let ascii = char.utf8.first else { return nil }
        if ascii >= 97 && ascii <= 122 { // 'a'...'z' -> KEYCODE_A (29)...KEYCODE_Z (54)
            return UInt32(ascii - 97) + 29
        }
        if ascii >= 48 && ascii <= 57 { // '0'...'9' -> KEYCODE_0 (7)...KEYCODE_9 (16)
            return UInt32(ascii - 48) + 7
        }
        return nil
    }
}
