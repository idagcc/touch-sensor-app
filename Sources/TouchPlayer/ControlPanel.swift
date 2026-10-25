import AppKit
import TouchPlayerCore

private let ink = NSColor(srgbRed: 0.055, green: 0.071, blue: 0.078, alpha: 1)
private let cardColor = NSColor(srgbRed: 0.09, green: 0.11, blue: 0.12, alpha: 1)
private let mint = NSColor(srgbRed: 0.65, green: 0.94, blue: 0.77, alpha: 1)
private let secondary = NSColor(srgbRed: 0.55, green: 0.61, blue: 0.62, alpha: 1)

final class ActionButton: NSButton {
    var handler: (() -> Void)?
    init(_ title: String, primary: Bool = false, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title
        self.handler = action
        bezelStyle = .rounded
        controlSize = .large
        font = .systemFont(ofSize: 12, weight: .semibold)
        target = self
        self.action = #selector(invoke)
        if primary { bezelColor = mint; contentTintColor = ink }
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 34).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func invoke() { handler?() }
}

final class ControlPanel: NSWindowController {
    let previewHost = NSView()
    let stateLabel = ControlPanel.label("HOLDING", size: 11, weight: .bold, color: mint)
    let timeLabel = ControlPanel.label("00:00 / 00:00", size: 11, color: secondary)
    let connectionLabel = ControlPanel.label("●  Disconnected", size: 11, color: secondary)
    let headline = ControlPanel.label("Ready for the next touch.", size: 28, weight: .semibold)
    let mediaLabel = ControlPanel.label("", size: 11, color: secondary)
    let rootLabel = ControlPanel.label("", size: 10, color: secondary)
    let ports = NSPopUpButton()
    let baud = NSPopUpButton()
    let displays = NSPopUpButton()
    let scaling = NSPopUpButton()
    let ending = NSPopUpButton()
    let widthField = ControlPanel.field("1920", width: 76)
    let heightField = ControlPanel.field("1080", width: 76)
    let toggleCommand = ControlPanel.field("0", width: 60)
    let restartCommand = ControlPanel.field("", width: 60)
    let resetCommand = ControlPanel.field("1", width: 60)
    let startupOutput = NSButton(checkboxWithTitle: "Open full screen on launch", target: nil, action: nil)
    let autoConnect = NSButton(checkboxWithTitle: "Reconnect automatically", target: nil, action: nil)
    let logView = NSTextView()
    private(set) var connectButton: ActionButton!
    private(set) var fullscreenButton: ActionButton!
    var onConnect: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onApply: (() -> Void)?
    var onReload: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onChooseFolder: (() -> Void)?
    var onOpenConfig: (() -> Void)?
    var onOutput: (() -> Void)?
    var onPreview: (() -> Void)?
    var onAction: ((PlayerAction) -> Void)?
    private var logLines: [String] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1070, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Touch Player"
        window.minSize = NSSize(width: 1020, height: 810)
        window.backgroundColor = ink
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        let root = stack(.vertical, spacing: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])
        let brand = Self.label("◉  TOUCH PLAYER", size: 13, weight: .bold, color: mint)
        root.addArrangedSubview(row([brand, spacer(), connectionLabel]))
        let intro = stack(.vertical, spacing: 7)
        intro.addArrangedSubview(headline)
        intro.addArrangedSubview(Self.label("Two videos. One touch. A simple, reliable playback station.", size: 13, color: secondary))
        root.addArrangedSubview(intro)

        let middle = stack(.horizontal, spacing: 18)
        middle.alignment = .top
        let left = stack(.vertical, spacing: 12)
        left.addArrangedSubview(row([Self.label("LIVE OUTPUT", size: 10, weight: .bold, color: secondary), spacer(), stateLabel]))
        previewHost.wantsLayer = true
        previewHost.layer?.backgroundColor = NSColor.black.cgColor
        previewHost.layer?.cornerRadius = 9
        previewHost.layer?.masksToBounds = true
        previewHost.translatesAutoresizingMaskIntoConstraints = false
        previewHost.heightAnchor.constraint(equalToConstant: 224).isActive = true
        let liveMessage = Self.label("Output is open in a separate window", size: 13, color: secondary)
        liveMessage.translatesAutoresizingMaskIntoConstraints = false
        previewHost.addSubview(liveMessage)
        NSLayoutConstraint.activate([liveMessage.centerXAnchor.constraint(equalTo: previewHost.centerXAnchor), liveMessage.centerYAnchor.constraint(equalTo: previewHost.centerYAnchor)])
        left.addArrangedSubview(previewHost)
        left.addArrangedSubview(row([mediaLabel, spacer(), timeLabel]))
        let transport = row([
            ActionButton("▶  Play / pause", primary: true) { [weak self] in self?.onAction?(.toggle) },
            ActionButton("↺  Return to holding") { [weak self] in self?.onAction?(.reset) },
            ActionButton("↻  Restart video") { [weak self] in self?.onAction?(.restart) }, spacer()
        ])
        left.addArrangedSubview(transport)
        let leftCard = card(left)
        middle.addArrangedSubview(leftCard)

        let serial = stack(.vertical, spacing: 11)
        serial.addArrangedSubview(Self.label("ARDUINO CONNECTION", size: 10, weight: .bold, color: secondary))
        serial.addArrangedSubview(Self.label("Serial port", size: 12))
        ports.toolTip = "Select the Arduino /dev/cu.* port. Close Arduino Serial Monitor first."
        serial.addArrangedSubview(row([ports, ActionButton("↻") { [weak self] in self?.onRefresh?() }]))
        serial.addArrangedSubview(row([Self.label("Baud rate", size: 12), spacer(), baud]))
        baud.addItems(withTitles: SerialTransport.supportedBaudRates.map(String.init))
        autoConnect.font = .systemFont(ofSize: 11)
        serial.addArrangedSubview(autoConnect)
        connectButton = ActionButton("Connect Arduino", primary: true) { [weak self] in self?.onConnect?() }
        serial.addArrangedSubview(connectButton)
        serial.addArrangedSubview(Self.label("SERIAL ACTIVITY", size: 10, weight: .bold, color: secondary))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = logView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 90).isActive = true
        logView.isEditable = false
        logView.isSelectable = true
        logView.drawsBackground = false
        logView.textColor = secondary
        logView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logView.textContainerInset = NSSize(width: 0, height: 4)
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true
        serial.addArrangedSubview(scroll)
        let serialCard = card(serial)
        serialCard.widthAnchor.constraint(equalToConstant: 292).isActive = true
        middle.addArrangedSubview(serialCard)
        leftCard.widthAnchor.constraint(equalTo: middle.widthAnchor, constant: -310).isActive = true
        root.addArrangedSubview(middle)

        let settings = stack(.vertical, spacing: 13)
        settings.addArrangedSubview(row([Self.label("OUTPUT & COMMANDS", size: 10, weight: .bold, color: secondary), spacer(), Self.label("0 / Space  play/pause    1 / R  holding    F  full screen    Esc  return", size: 10, color: secondary)]))
        scaling.addItems(withTitles: ["Fit · keep entire video", "Fill · crop to canvas", "Stretch · fill canvas"])
        ending.addItems(withTitles: ["Return to holding", "Freeze last frame", "Quit app"])
        displays.translatesAutoresizingMaskIntoConstraints = false
        displays.widthAnchor.constraint(equalToConstant: 220).isActive = true
        settings.addArrangedSubview(row([
            Self.label("Canvas", size: 12), widthField, Self.label("×", size: 12, color: secondary), heightField,
            Self.label("px", size: 11, color: secondary), spacer(), scaling, displays
        ]))
        settings.addArrangedSubview(row([
            Self.label("Play / pause", size: 12), toggleCommand,
            Self.label("Return to holding", size: 12), resetCommand,
            Self.label("Restart (optional)", size: 12), restartCommand, spacer(),
            Self.label("At end", size: 12), ending
        ]))
        startupOutput.font = .systemFont(ofSize: 11)
        settings.addArrangedSubview(row([startupOutput, spacer(), ActionButton("Save settings") { [weak self] in self?.onApply?() }]))
        root.addArrangedSubview(card(settings))

        fullscreenButton = ActionButton("↗  Launch full screen", primary: true) { [weak self] in self?.onOutput?() }
        root.addArrangedSubview(row([
            ActionButton("Video folders") { [weak self] in self?.onOpenFolder?() },
            ActionButton("Reload media & JSON") { [weak self] in self?.onReload?() },
            ActionButton("Edit config.json") { [weak self] in self?.onOpenConfig?() },
            spacer(),
            ActionButton("Windowed output") { [weak self] in self?.onPreview?() },
            fullscreenButton
        ]))
        rootLabel.lineBreakMode = .byTruncatingMiddle
        root.addArrangedSubview(row([rootLabel, spacer(), ActionButton("Choose data folder…") { [weak self] in self?.onChooseFolder?() }]))
        root.arrangedSubviews.forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
    }

    func embed(_ surface: NSView) {
        surface.removeFromSuperview()
        surface.translatesAutoresizingMaskIntoConstraints = false
        previewHost.addSubview(surface)
        NSLayoutConstraint.activate([surface.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor), surface.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor), surface.topAnchor.constraint(equalTo: previewHost.topAnchor), surface.bottomAnchor.constraint(equalTo: previewHost.bottomAnchor)])
    }

    func addLog(_ message: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logLines.append("\(stamp)  \(message)")
        logLines = Array(logLines.suffix(120))
        logView.string = logLines.joined(separator: "\n")
        logView.scrollToEndOfDocument(nil)
    }

    func setConnection(_ phase: SerialConnectionPhase) {
        switch phase {
        case .connected: connectionLabel.stringValue = "●  Arduino connected"
        case .connecting: connectionLabel.stringValue = "◌  Connecting Arduino"
        case .settling: connectionLabel.stringValue = "◌  Arduino starting"
        case .waiting: connectionLabel.stringValue = "◌  Waiting / reconnecting"
        case .suspended: connectionLabel.stringValue = "◌  Serial suspended"
        case .disconnected: connectionLabel.stringValue = "●  Disconnected"
        }
        connectionLabel.textColor = phase == .connected ? mint : secondary
        connectButton.title = phase == .disconnected ? "Connect Arduino" : (phase == .connected ? "Disconnect" : "Cancel connection")
    }

    static func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .white) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func field(_ text: String, width: CGFloat) -> NSTextField {
        let field = NSTextField(string: text)
        field.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        field.alignment = .center
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    private func stack(_ orientation: NSUserInterfaceLayoutOrientation, spacing: CGFloat) -> NSStackView {
        let view = NSStackView()
        view.orientation = orientation
        view.spacing = spacing
        view.alignment = orientation == .vertical ? .leading : .centerY
        view.distribution = .fill
        return view
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let view = stack(.horizontal, spacing: 10)
        views.forEach(view.addArrangedSubview)
        return view
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }

    private func card(_ inner: NSStackView) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = cardColor.cgColor
        view.layer?.cornerRadius = 12
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor(white: 1, alpha: 0.065).cgColor
        inner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(inner)
        NSLayoutConstraint.activate([inner.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 17), inner.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -17), inner.topAnchor.constraint(equalTo: view.topAnchor, constant: 16), inner.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)])
        inner.arrangedSubviews.forEach { child in
            child.translatesAutoresizingMaskIntoConstraints = false
            child.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        }
        return view
    }
}
