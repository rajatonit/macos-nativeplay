// On-screen settings panel over the video (S or Cmd-, shows and hides it). Everything here can also be
// changed with the single-key shortcuts; both go through the same RenderView setters, so the panel
// always shows what's actually running.

import AppKit

final class SettingsPanel: NSVisualEffectView {
    private weak var renderView: RenderView?
    /// Microphone state, nil when there's no live session (file playback).
    var micLive: (() -> Bool?)?
    var toggleMic: (() -> Void)?

    private let power = NSSegmentedControl(labels: RenderView.Power.allCases.map(\.name), trackingMode: .selectOne, target: nil, action: nil)
    private let powerNote = NSTextField(labelWithString: "")
    private let upscaler = NSPopUpButton()
    private let interpolation = NSButton(checkboxWithTitle: "120 fps frame generation", target: nil, action: nil)
    private let interpolationNote = NSTextField(labelWithString: "Only runs in Max")
    private let boost = NSButton(checkboxWithTitle: "HDR highlight boost", target: nil, action: nil)
    private let cleanup = NSButton(checkboxWithTitle: "Artifact clean-up", target: nil, action: nil)
    private let mic = NSButton(checkboxWithTitle: "Microphone", target: nil, action: nil)
    private let fps = NSButton(checkboxWithTitle: "FPS counter on screen", target: nil, action: nil)
    private let compare = NSButton(checkboxWithTitle: "Split screen: standard | enhanced", target: nil, action: nil)
    private let record = NSButton(title: "Start recording", target: nil, action: nil)
    private let recordNote = NSTextField(labelWithString: "Saves to Movies (R)")

    init(renderView: RenderView) {
        self.renderView = renderView
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .vibrantDark)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let hint = NSTextField(labelWithString: "S to hide")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let close = NSButton(title: "Hide", target: self, action: #selector(hide))
        close.bezelStyle = .rounded
        close.controlSize = .small
        let header = NSStackView(views: [title, hint, NSView(), close])
        header.alignment = .firstBaseline

        for note in [powerNote, interpolationNote, recordNote] {
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
        }
        power.target = self; power.action = #selector(powerChanged)
        upscaler.addItems(withTitles: RenderView.Upscale.allCases.map(\.rawValue))
        upscaler.target = self; upscaler.action = #selector(upscalerChanged)
        record.bezelStyle = .rounded
        record.controlSize = .small
        for b in [interpolation, boost, cleanup, mic, compare, record, fps] { b.target = self; b.action = #selector(toggled(_:)) }

        func row(_ label: String, _ views: NSView...) -> NSView {
            let l = NSTextField(labelWithString: label)
            l.textColor = .secondaryLabelColor
            l.alignment = .right
            l.widthAnchor.constraint(equalToConstant: 78).isActive = true
            let right = NSStackView(views: views)
            right.orientation = .vertical
            right.alignment = .leading
            right.spacing = 3
            let r = NSStackView(views: [l, right])
            r.alignment = .firstBaseline
            return r
        }
        let stack = NSStackView(views: [
            header,
            row("Power", power, powerNote),
            row("Upscaler", upscaler),
            row("Motion", interpolation, interpolationNote),
            row("Picture", boost, cleanup, compare, fps),
            row("Audio", mic),
            row("Capture", record, recordNote),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            widthAnchor.constraint(equalToConstant: 340),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Re-reads every setting from the renderer.
    func refresh() {
        guard let v = renderView else { return }
        power.selectedSegment = v.chosenPower.rawValue
        powerNote.stringValue = v.power != v.chosenPower
            ? "Running \(v.power.name) because of \(v.powerLimitReason)"
            : ["Neural fast, 60 fps", "Neural HQ, 60 fps", "Neural HQ + 120 fps frame generation"][v.chosenPower.rawValue]
        upscaler.selectItem(withTitle: v.upscale.rawValue)
        interpolation.state = v.interpolationEnabled ? .on : .off
        interpolation.isEnabled = FrameInterpolator.isSupported
        interpolationNote.isHidden = v.power == .max
        boost.state = v.highlightBoost ? .on : .off
        cleanup.state = v.cleanup ? .on : .off
        compare.state = v.compare ? .on : .off
        fps.state = v.showFPS ? .on : .off
        record.title = v.isRecording ? "Stop recording" : "Start recording"
        recordNote.stringValue = v.isRecording ? "Recording… (R to stop)" : "Saves to Movies (R)"
        if let live = micLive?() {
            mic.isEnabled = true
            mic.state = live ? .on : .off
        } else {
            mic.isEnabled = false
            mic.state = .off
        }
    }

    @objc private func powerChanged() {
        renderView?.setPower(RenderView.Power(rawValue: power.selectedSegment) ?? .balanced)
        done()
    }
    @objc private func upscalerChanged() {
        if let t = upscaler.titleOfSelectedItem, let u = RenderView.Upscale(rawValue: t) { renderView?.setUpscale(u) }
        done()
    }
    @objc private func toggled(_ b: NSButton) {
        guard let v = renderView else { return }
        switch b {
        case interpolation: v.setInterpolation(b.state == .on)
        case boost: v.setHighlightBoost(b.state == .on)
        case cleanup: v.setCleanup(b.state == .on)
        case mic: toggleMic?()
        case compare: v.setCompare(b.state == .on)
        case fps: v.setShowFPS(b.state == .on)
        case record: v.toggleRecording()
        default: break
        }
        done()
    }
    @objc private func hide() { renderView?.onToggleSettings?() }

    /// After a click, keys go back to the game.
    private func done() {
        refresh()
        if let v = renderView { window?.makeFirstResponder(v) }
    }
}

/// Window content: the video, with the settings panel floating over its top-left corner.
final class VideoContainer: NSView {
    let video: RenderView
    let settings: SettingsPanel

    init(video: RenderView) {
        self.video = video
        settings = SettingsPanel(renderView: video)
        super.init(frame: .zero)
        // The video view hosts its own Metal layer, so the panel is a sibling above it, not a child.
        video.autoresizingMask = [.width, .height]
        addSubview(video)
        settings.translatesAutoresizingMaskIntoConstraints = false
        settings.isHidden = true
        addSubview(settings)
        NSLayoutConstraint.activate([
            settings.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            settings.topAnchor.constraint(equalTo: topAnchor, constant: 20),
        ])
        video.onSettingsChanged = { [weak self] in self?.settings.refresh() }
        video.onToggleSettings = { [weak self] in self?.toggleSettings() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        video.frame = bounds
    }

    @objc func toggleSettings() {
        settings.isHidden.toggle()
        if !settings.isHidden { settings.refresh() }
        video.keepsCursor = !settings.isHidden
        window?.makeFirstResponder(video)
        print("settings panel \(settings.isHidden ? "hidden" : "shown")")
    }
}
