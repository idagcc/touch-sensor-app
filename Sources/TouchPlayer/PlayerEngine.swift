import AppKit
import AVFoundation
import TouchPlayerCore

final class VideoSurface: NSView {
    let videoLayer = AVPlayerLayer()
    var canvasSize = CGSize(width: 1920, height: 1080) { didSet { needsLayout = true } }
    var scaleMode = "fit" { didSet { needsLayout = true } }
    private let message = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(videoLayer)
        videoLayer.backgroundColor = NSColor.black.cgColor
        message.alignment = .center
        message.textColor = NSColor(white: 0.55, alpha: 1)
        message.font = .systemFont(ofSize: 15, weight: .medium)
        message.translatesAutoresizingMaskIntoConstraints = false
        addSubview(message)
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: centerXAnchor),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func showMessage(_ text: String) { message.stringValue = text; message.isHidden = text.isEmpty }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Preserve the custom canvas aspect ratio inside the physical screen.
        let factor = min(bounds.width / canvasSize.width, bounds.height / canvasSize.height)
        let size = CGSize(width: canvasSize.width * factor, height: canvasSize.height * factor)
        videoLayer.frame = CGRect(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2, width: size.width, height: size.height)
        videoLayer.videoGravity = scaleMode == "stretch" ? .resize : (scaleMode == "fill" ? .resizeAspectFill : .resizeAspect)
        CATransaction.commit()
    }
}

final class PlayerEngine {
    let surface = VideoSurface(frame: .zero)
    private let holding = AVQueuePlayer()
    private let playback = AVPlayer()
    private var looper: AVPlayerLooper?
    private var observers: [NSObjectProtocol] = []
    private var observations: [NSKeyValueObservation] = []
    private var pendingPlaybackSeek = false
    private var seekGeneration = 0
    private var machine = PlaybackMachine()
    private var config = Configuration()
    private(set) var holdingURL: URL?
    private(set) var playbackURL: URL?
    var state: PlaybackState { machine.state }
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    var onQuit: (() -> Void)?
    var onEvent: ((String) -> Void)?

    init() {
        playback.actionAtItemEnd = .pause
        observers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            guard let self, let item = notification.object as? AVPlayerItem, item === self.playback.currentItem else { return }
            if self.config.videos.endBehavior == "quit" { self.onQuit?(); return }
            if self.config.videos.endBehavior == "holding" { self.perform(.reset) }
            else {
                self.playback.pause()
                // At the exact duration AVPlayerLayer may have no image to present.
                // Seek inside the final frame so freeze mode retains its pixels.
                let duration = item.duration.seconds
                if duration.isFinite, duration > 0 {
                    self.playback.seek(to: CMTime(seconds: max(0, duration - 0.001), preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
                }
                self.machine.finish(returnToHolding: false)
                self.onChange?()
            }
            self.onEvent?("Playback finished → \(self.config.videos.endBehavior)")
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            guard let self, let item = notification.object as? AVPlayerItem,
                  item === self.playback.currentItem || self.holding.items().contains(where: { $0 === item }) else { return }
            self.onError?("Video playback failed. Try an H.264 MP4 or ProRes MOV file.")
            self.perform(.reset)
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func load(config: Configuration, holdingURL: URL?, playbackURL: URL?) {
        seekGeneration += 1
        pendingPlaybackSeek = false
        observations.removeAll()
        holding.pause(); playback.pause()
        looper?.disableLooping(); looper = nil
        holding.removeAllItems()
        self.config = config
        self.holdingURL = holdingURL
        self.playbackURL = playbackURL
        holding.isMuted = config.videos.muteHolding
        holding.volume = Float(config.videos.volume)
        playback.volume = Float(config.videos.volume)
        surface.canvasSize = CGSize(width: config.output.width, height: config.output.height)
        surface.scaleMode = config.output.scale
        if let url = holdingURL {
            let item = AVPlayerItem(url: url)
            looper = AVPlayerLooper(player: holding, templateItem: item)
            if let looper {
                observations.append(looper.observe(\.status, options: [.new]) { [weak self] looper, _ in
                    guard looper.status == .failed else { return }
                    DispatchQueue.main.async { self?.onError?("Holding video could not be played: \(looper.error?.localizedDescription ?? "unsupported format")") }
                })
            }
        }
        playback.replaceCurrentItem(with: playbackURL.map(AVPlayerItem.init(url:)))
        if let item = playback.currentItem {
            observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                DispatchQueue.main.async {
                    self?.onError?("Playback video could not be opened: \(item.error?.localizedDescription ?? "unsupported format")")
                    self?.perform(.reset)
                }
            })
        }
        perform(.reset)
    }

    func perform(_ action: PlayerAction) {
        if action == .quit { onQuit?(); return }
        let previous = state
        if [.play, .toggle, .restart].contains(action), playbackURL == nil {
            onError?("Add a video to the playback folder, then click Reload media.")
            return
        }
        if action == .pause, state != .playing { return }
        machine.apply(action)
        if action == .reset {
            seekGeneration += 1; pendingPlaybackSeek = false
            playback.pause()
            playback.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            surface.videoLayer.player = holding
            surface.showMessage(holdingURL == nil ? "Add a video to media/holding\nThen click Reload media" : "")
            holding.play()
        } else {
            holding.pause()
            surface.videoLayer.player = playback
            surface.showMessage("")
            if state == .paused { playback.pause() }
            else if action == .restart || previous == .holding || previous == .finished {
                seekGeneration += 1
                let token = seekGeneration
                pendingPlaybackSeek = true
                playback.pause()
                playback.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
                    DispatchQueue.main.async {
                        guard let self, self.seekGeneration == token else { return }
                        self.pendingPlaybackSeek = false
                        if completed, self.state == .playing { self.playback.play() }
                    }
                }
            } else if !pendingPlaybackSeek { playback.play() }
        }
        onChange?()
    }

    var timing: (Double, Double) {
        let player: AVPlayer = state == .holding ? holding : playback
        let time = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        return (time.isFinite ? time : 0, duration.isFinite ? duration : 0)
    }

    func stop() { holding.pause(); playback.pause() }
}
