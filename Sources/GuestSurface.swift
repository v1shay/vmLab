import AppKit
import SwiftUI

struct GuestSurface: NSViewRepresentable {
    let machine: Machine
    let frame: CGImage

    func makeNSView(context: Context) -> Surface {
        let view = Surface()
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .never
        view.layer?.contentsGravity = .resize
        view.setAccessibilityLabel("Guest display. Click to focus. Escape releases input.")
        return view
    }

    func updateNSView(_ view: Surface, context: Context) {
        view.attach(machine)
        view.present(machine.frame ?? frame)
    }

    static func dismantleNSView(_ view: Surface, coordinator: ()) { view.detach() }

    final class Surface: NSView {
        weak var machine: Machine?
        var pixels = CGSize.zero
        private var observation: UUID?
        private var scrollRemainder: CGFloat = 0

        func attach(_ machine: Machine) {
            guard self.machine !== machine else { return }
            detach()
            self.machine = machine
            observation = machine.frames.observe { [weak self] frame in self?.present(frame) }
        }
        func detach() {
            if let observation { machine?.frames.remove(observation) }
            observation = nil
            machine = nil
        }
        func present(_ frame: CGImage?) {
            pixels = frame.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = frame
            CATransaction.commit()
        }
        private var pressed: [UInt16: UInt32] = [:]
        private var buttons: UInt8 = 0
        private var lastPoint: (UInt16, UInt16) = (0, 0)
        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            sendPointer(event, buttons: 1)
        }

        override func mouseDragged(with event: NSEvent) { sendPointer(event, buttons: 1) }
        override func mouseUp(with event: NSEvent) { sendPointer(event, buttons: 0) }

        private func sendPointer(_ event: NSEvent, buttons: UInt8) {
            guard bounds.width > 0, bounds.height > 0, pixels.width > 0, pixels.height > 0 else { return }
            let point = convert(event.locationInWindow, from: nil)
            let x = min(max(point.x / bounds.width * pixels.width, 0), pixels.width - 1)
            let y = min(max((bounds.height - point.y) / bounds.height * pixels.height, 0), pixels.height - 1)
            lastPoint = (UInt16(x), UInt16(y))
            self.buttons = buttons
            if let display = machine?.display { machine?.input.pointer(display, x: lastPoint.0, y: lastPoint.1, buttons: buttons) }
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {
                window?.makeFirstResponder(nil)
                return
            }
            let special: [UInt16: UInt32] = [
                36: 0xff0d, 48: 0xff09, 51: 0xff08, 117: 0xffff,
                123: 0xff51, 124: 0xff53, 125: 0xff54, 126: 0xff52,
            ]
            let character = event.characters?.unicodeScalars.first?.value
            guard let key = special[event.keyCode] ?? character.map({ $0 < 256 ? $0 : 0x01000000 | $0 }) else { return }
            pressed[event.keyCode] = key
            if let display = machine?.display { machine?.input.key(display, key: key, down: true) }
        }

        override func keyUp(with event: NSEvent) {
            guard let key = pressed.removeValue(forKey: event.keyCode) else { return }
            if let display = machine?.display { machine?.input.key(display, key: key, down: false) }
        }

        override func scrollWheel(with event: NSEvent) {
            guard let display = machine?.display else { return }
            scrollRemainder += event.scrollingDeltaY
            let step: CGFloat = event.hasPreciseScrollingDeltas ? 20 : 1
            let count = min(12, Int(abs(scrollRemainder) / step))
            guard count > 0 else { return }
            let wheel: UInt8 = scrollRemainder > 0 ? 8 : 16
            scrollRemainder += (scrollRemainder > 0 ? -1 : 1) * CGFloat(count) * step
            for _ in 0..<count {
                machine?.input.pointer(display, x: lastPoint.0, y: lastPoint.1, buttons: buttons | wheel)
                machine?.input.pointer(display, x: lastPoint.0, y: lastPoint.1, buttons: buttons)
            }
        }

        override func resignFirstResponder() -> Bool {
            for key in pressed.values {
                if let display = machine?.display { machine?.input.key(display, key: key, down: false) }
            }
            pressed.removeAll()
            if buttons != 0 {
                if let display = machine?.display { machine?.input.pointer(display, x: lastPoint.0, y: lastPoint.1, buttons: 0) }
                buttons = 0
            }
            return super.resignFirstResponder()
        }
    }
}

/// Only the newest decoded frame gets an AppKit delivery when the main queue is busy.
final class LatestFrameDelivery {
    private let lock = NSLock()
    private var pending: CGImage?
    private var scheduled = false
    private let receive: (CGImage) -> Void

    init(_ receive: @escaping (CGImage) -> Void) { self.receive = receive }
    func submit(_ image: CGImage) {
        lock.lock()
        pending = image
        if scheduled { lock.unlock(); return }
        scheduled = true
        lock.unlock()
        DispatchQueue.main.async { [self] in
            lock.lock()
            let latest = pending
            pending = nil
            scheduled = false
            lock.unlock()
            if let latest { receive(latest) }
        }
    }
}

/// Frame changes update the compositor layer without rebuilding the SwiftUI hierarchy.
final class GuestFrames {
    private var observers: [UUID: (CGImage?) -> Void] = [:]
    func observe(_ callback: @escaping (CGImage?) -> Void) -> UUID {
        let id = UUID()
        observers[id] = callback
        return id
    }
    func remove(_ id: UUID) { observers.removeValue(forKey: id) }
    func present(_ image: CGImage?) { for callback in observers.values { callback(image) } }
}

/// Serialize key transitions and coalesce adjacent motion events off the UI thread.
final class GuestInput {
    private enum Event {
        case key(RFB, UInt32, Bool)
        case pointer(RFB, UInt16, UInt16, UInt8)
        case operation(() -> Void)
    }
    private let queue = DispatchQueue(label: "vmlab.guest-input", qos: .userInteractive)
    private let lock = NSLock()
    private var events: [Event] = []
    private var draining = false

    func operation(_ body: @escaping () -> Void) { append(.operation(body)) }
    func key(_ display: RFB, key: UInt32, down: Bool) { append(.key(display, key, down)) }
    func pointer(_ display: RFB, x: UInt16, y: UInt16, buttons: UInt8) {
        append(.pointer(display, x, y, buttons))
    }
    private func append(_ event: Event) {
        lock.lock()
        if case let .pointer(display, _, _, buttons) = event,
           case let .pointer(previous, _, _, oldButtons)? = events.last,
           previous === display, buttons == oldButtons {
            events[events.count - 1] = event
        } else { events.append(event) }
        if draining { lock.unlock(); return }
        draining = true
        lock.unlock()
        queue.async { [self] in
            while true {
                lock.lock()
                guard !events.isEmpty else { draining = false; lock.unlock(); return }
                let event = events.removeFirst()
                lock.unlock()
                switch event {
                case let .key(display, key, down): try? display.key(key, down: down)
                case let .pointer(display, x, y, buttons): try? display.pointer(x: x, y: y, buttons: buttons)
                case let .operation(body): body()
                }
            }
        }
    }
}
