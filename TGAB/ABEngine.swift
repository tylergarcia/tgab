//
//  ABSwitcherApp.swift
//  AB Switcher – one‑file demo
//
//  Created by ChatGPT on 2025‑04‑21.
//

import SwiftUI
import AVFoundation
import Combine

// MARK: – Audio Engine wrapper
@MainActor
final class ABEngine: ObservableObject {

    enum ActiveSide { case a, b }

    // Published UI‑bound properties
    @Published var fileAName: String = "— no file —"
    @Published var fileBName: String = "— no file —"
    @Published var meterA: Float = -80     // dBFS
    @Published var meterB: Float = -80
    @Published var active: ActiveSide = .a
    @Published var isPlaying = false
    @Published var gainA: Float = 1.0       // linear (0…1.0 == 0 dB)
    @Published var gainB: Float = 1.0
    @Published var meterALeft: Float = -80  // dBFS
    @Published var meterARight: Float = -80
    @Published var meterBLeft: Float = -80
    @Published var meterBRight: Float = -80
    @Published var waveformA: [Float] = []
    @Published var waveformB: [Float] = []
    @Published var waveformImageA: CGImage?
    @Published var waveformImageB: CGImage?
    @Published var waveformPathA: CGPath?
    @Published var waveformPathB: CGPath?
    // --- New: keep references to the files & playback progress ---
    private var fileA: AVAudioFile?
    private var fileB: AVAudioFile?
    @Published var progress: Double = 0       // 0.0 … 1.0
    var gainADecibels: Float { 20 * log10(max(gainA, 0.0001)) }
    var gainBDecibels: Float { 20 * log10(max(gainB, 0.0001)) }
    @Published var attackTime: Float = 0.01   // seconds to attack (99%)
    @Published var releaseTime: Float = 0.3   // seconds to release (99%)
    @Published var presets: [String] = []
    private let presetsKey = "ABEnginePresets"

    // Internals
    private let engine = AVAudioEngine()
    private let playerA = AVAudioPlayerNode()
    private let playerB = AVAudioPlayerNode()
    private let mixer   = AVAudioMixerNode()          // master
    private var progressTimer: Timer?
    /// Normalized starting offset used for accurate progress after seeking
    private var baseOffset: Double = 0.0
    private var cancellables = Set<AnyCancellable>()

    // Meter ballistics settings
    @Published var meterInertia: Float = 0.3  // seconds to reach 99% (tweak as needed)
    private var meterReadoutA: Float = 0     // linear readout level (0…1)
    private var meterReadoutB: Float = 0
    private var meterReadoutALeft: Float = 0
    private var meterReadoutARight: Float = 0
    private var meterReadoutBLeft: Float = 0
    private var meterReadoutBRight: Float = 0

    init() {
        // Attach nodes
        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(mixer)

        // Connect players → mixer → mainOut
        engine.connect(playerA, to: mixer, format: nil)
        engine.connect(playerB, to: mixer, format: nil)
        engine.connect(mixer,   to: engine.mainMixerNode, format: nil)

        // Start engine early
        try? engine.start()

        // Stereo meter taps for playerA
        playerA.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            guard let self = self else { return }
            let rate = Float(buf.format.sampleRate)
            let frames = Int(buf.frameLength)
            let ptrL = buf.floatChannelData![0]
            let ptrR = buf.floatChannelData![1]
            var maxL: Float = 0, maxR: Float = 0
            for i in 0..<frames {
                maxL = max(maxL, abs(ptrL[i]))
                maxR = max(maxR, abs(ptrR[i]))
            }
            // ballistics
            let dt = Float(buf.frameLength) / rate
            let c = pow(0.01, dt / self.meterInertia)
            let rawL = maxL / max(self.gainA, 0.0001)
            let rawR = maxR / max(self.gainA, 0.0001)
            self.meterReadoutALeft  = c * (self.meterReadoutALeft  - rawL) + rawL
            self.meterReadoutARight = c * (self.meterReadoutARight - rawR) + rawR
            let toDB: (Float)->Float = { $0 == 0 ? -80 : 20 * log10($0) }
            DispatchQueue.main.async {
                self.meterALeft  = toDB(min(self.meterReadoutALeft, 1))
                self.meterARight = toDB(min(self.meterReadoutARight, 1))
            }
        }
        // Stereo meter taps for playerB
        playerB.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            guard let self = self else { return }
            let rate = Float(buf.format.sampleRate)
            let frames = Int(buf.frameLength)
            let ptrL = buf.floatChannelData![0]
            let ptrR = buf.floatChannelData![1]
            var maxL: Float = 0, maxR: Float = 0
            for i in 0..<frames {
                maxL = max(maxL, abs(ptrL[i]))
                maxR = max(maxR, abs(ptrR[i]))
            }
            // ballistics
            let dt = Float(buf.frameLength) / rate
            let c = pow(0.01, dt / self.meterInertia)
            let rawL = maxL / max(self.gainB, 0.0001)
            let rawR = maxR / max(self.gainB, 0.0001)
            self.meterReadoutBLeft  = c * (self.meterReadoutBLeft  - rawL) + rawL
            self.meterReadoutBRight = c * (self.meterReadoutBRight - rawR) + rawR
            let toDB: (Float)->Float = { $0 == 0 ? -80 : 20 * log10($0) }
            DispatchQueue.main.async {
                self.meterBLeft  = toDB(min(self.meterReadoutBLeft, 1))
                self.meterBRight = toDB(min(self.meterReadoutBRight, 1))
            }
        }

        // Observers for gain + active switching
        $gainA.sink { [weak self] v in
            self?.playerA.volume = (self?.active == .a ? v : 0)
            let db = 20 * log10(max(v, 0.0001))
            let dbStr = String(format: "%.1f", db)
            print("Gain A set to \(v) linear (~\(dbStr) dB)")
        }.store(in: &cancellables)
        $gainB.sink { [weak self] v in
            self?.playerB.volume = (self?.active == .b ? v : 0)
            let db = 20 * log10(max(v, 0.0001))
            let dbStr = String(format: "%.1f", db)
            print("Gain B set to \(v) linear (~\(dbStr) dB)")
        }.store(in: &cancellables)
        $active.sink { [weak self] side in
            guard let self else { return }
            playerA.volume = side == .a ? gainA : 0
            playerB.volume = side == .b ? gainB : 0
        }.store(in: &cancellables)

        // (Removed legacy mixer meter tap)
    }

    // MARK: file loading
    func loadFile(side: ActiveSide) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let file = try AVAudioFile(forReading: url)
                schedule(file: file, on: side)
                // store a reference so we can restart playback & compute progress
                if side == .a { self.fileA = file } else { self.fileB = file }
                // extract waveform data for UI display
                if side == .a {
                    waveformA = extractWaveform(from: file)
                    // pre-render image at 2000px width, 80px height
                    let w = min(waveformA.count, 2000)
                    waveformImageA = generateWaveformImage(from: waveformA, width: w, height: 80)
                    // pre-render vector path at 2000px width, 80px height
                    waveformPathA = generateWaveformPath(from: waveformA, width: w, height: 80)
                } else {
                    waveformB = extractWaveform(from: file)
                    let w = min(waveformB.count, 2000)
                    waveformImageB = generateWaveformImage(from: waveformB, width: w, height: 80)
                    waveformPathB = generateWaveformPath(from: waveformB, width: w, height: 80)
                }
                if side == .a { fileAName = url.lastPathComponent }
                else           { fileBName = url.lastPathComponent }
            } catch {
                debugPrint("Error loading: \(error)")
            }
        }
    }

    private func schedule(file: AVAudioFile, on side: ActiveSide) {
        let player = side == .a ? playerA : playerB
        player.stop()
        player.scheduleFile(file, at: nil, completionHandler: nil)
    }

    // MARK: Transport
    func play() {
        if !isPlaying {
            // require at least one file loaded
            guard fileA != nil || fileB != nil else { return }

            // reset progress and offset
            baseOffset = 0.0
            progress = 0

            // stop any current playback
            playerA.stop()
            playerB.stop()

            // schedule available files
            if let aFile = fileA {
                playerA.scheduleFile(aFile, at: nil, completionHandler: nil)
            }
            if let bFile = fileB {
                playerB.scheduleFile(bFile, at: nil, completionHandler: nil)
            }

            // start both players in sync (no-op if unscheduled)
            let startTime = AVAudioTime(hostTime: mach_absolute_time())
            playerA.play(at: startTime)
            playerB.play(at: startTime)

            isPlaying = true

            // restart progress timer
            progressTimer?.invalidate()
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                if let self { Task { @MainActor in self.updateProgress() } }
            }
            progressTimer?.tolerance = 0.03
        }
    }

    func stop() {
        playerA.stop()
        playerB.stop()
        isPlaying = false
        progressTimer?.invalidate()
        progress = 0
    }

    /// Seek both players to the specified normalized position (0.0–1.0).
    func seek(to position: Double) {
        guard let aFile = fileA, let bFile = fileB else { return }
        // clamp position
        let pos = max(0, min(position, 1))
        // compute start frame
        let startFrameA = AVAudioFramePosition(pos * Double(aFile.length))
        let startFrameB = AVAudioFramePosition(pos * Double(bFile.length))
        let countA = AVAudioFrameCount(aFile.length - startFrameA)
        let countB = AVAudioFrameCount(bFile.length - startFrameB)

        // stop and reschedule
        playerA.stop()
        playerB.stop()
        playerA.scheduleSegment(aFile, startingFrame: startFrameA, frameCount: countA, at: nil, completionHandler: nil)
        playerB.scheduleSegment(bFile, startingFrame: startFrameB, frameCount: countB, at: nil, completionHandler: nil)

        // update progress
        progress = pos

        // if playing, restart in sync
        if isPlaying {
            let start = AVAudioTime(hostTime: mach_absolute_time())
            playerA.play(at: start)
            playerB.play(at: start)
        }
    }

    /// Save current settings as a named preset
    func savePreset(named name: String) {
        var dict = UserDefaults.standard.dictionary(forKey: presetsKey) as? [String: [String: Float]] ?? [:]
        dict[name] = ["gainA": gainA,
                      "gainB": gainB,
                      "attackTime": attackTime,
                      "releaseTime": releaseTime]
        UserDefaults.standard.set(dict, forKey: presetsKey)
        loadPresets()
    }

    /// Load available preset names
    func loadPresets() {
        let dict = UserDefaults.standard.dictionary(forKey: presetsKey) as? [String: [String: Float]] ?? [:]
        presets = dict.keys.sorted()
    }

    /// Apply a saved preset by name
    func applyPreset(named name: String) {
        guard let dict = UserDefaults.standard.dictionary(forKey: presetsKey) as? [String: [String: Float]],
              let val = dict[name] else { return }
        gainA = val["gainA"] ?? gainA
        gainB = val["gainB"] ?? gainB
        attackTime  = val["attackTime"]  ?? attackTime
        releaseTime = val["releaseTime"] ?? releaseTime
    }

    /// Delete a preset by name
    func deletePreset(named name: String) {
        var dict = UserDefaults.standard.dictionary(forKey: presetsKey) as? [String: [String: Float]] ?? [:]
        dict.removeValue(forKey: name)
        UserDefaults.standard.set(dict, forKey: presetsKey)
        loadPresets()
    }

    // MARK: Meters
    // MARK: – progress helpers
    private func updateProgress() {
        // choose the active playback node and file (or single-loaded)
        let (node, file): (AVAudioPlayerNode, AVAudioFile) = {
            if fileA != nil && fileB == nil {
                return (playerA, fileA!)
            } else if fileB != nil && fileA == nil {
                return (playerB, fileB!)
            } else {
                // both loaded: use the selected side
                if active == .a {
                    return (playerA, fileA!)
                } else {
                    return (playerB, fileB!)
                }
            }
        }()

        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return }

        let secondsPlayed = Double(playerTime.sampleTime) / playerTime.sampleRate
        let frac = secondsPlayed / file.duration
        // combine with any base offset from seeking
        progress = min(1, baseOffset + frac)
    }
}

private extension ABEngine {
    /// Extract the full-resolution mono waveform from an AVAudioFile.
    /// - Parameter file: the audio file to read.
    /// - Returns: array of normalized (-1…1) samples.
    func extractWaveform(from file: AVAudioFile) -> [Float] {
        let totalFrames = Int(file.length)
        let framesToRead = AVAudioFrameCount(totalFrames)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: framesToRead) else {
            return []
        }
        do { try file.read(into: buffer) }
        catch { print("Failed to read waveform: \(error)"); return [] }
        // Read first channel full
        let channelData = buffer.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: channelData, count: totalFrames))
    }
}

// quick helper to compute file duration in seconds
private extension AVAudioFile {
    var duration: Double { Double(length) / processingFormat.sampleRate }
}


private extension ABEngine {
    /// Generate a pitched waveform CGImage from samples, bucketed to the given width/height.
    func generateWaveformImage(from samples: [Float], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, !samples.isEmpty else { return nil }
        // Bucket samples per pixel
        let total = samples.count
        let samplesPerPixel = max(1, total / width)

        // Create context with clear background
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: width,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setStrokeColor(CGColor(gray: 0.5, alpha: 1))
        ctx.setLineWidth(1)

        for x in 0..<width {
            let start = x * samplesPerPixel
            let end = min(start + samplesPerPixel, total)
            guard start < end else { continue }
            let bucket = samples[start..<end]
            let minSample = bucket.min() ?? 0
            let maxSample = bucket.max() ?? 0
            let midY = CGFloat(height) / 2
            let yMin = midY - CGFloat(minSample) * midY
            let yMax = midY - CGFloat(maxSample) * midY
            let xpos = CGFloat(x) + 0.5
            ctx.move(to: CGPoint(x: xpos, y: yMin))
            ctx.addLine(to: CGPoint(x: xpos, y: yMax))
            ctx.strokePath()
        }

        return ctx.makeImage()
    }
}

private extension ABEngine {
    /// Generate a CGPath for the waveform from raw samples, bucketed to the given width/height.
    func generateWaveformPath(from samples: [Float], width: Int, height: Int) -> CGPath? {
        guard width > 0, height > 0, !samples.isEmpty else { return nil }
        let total = samples.count
        let samplesPerPixel = max(1, total / width)
        let path = CGMutablePath()
        let midY = CGFloat(height) / 2
        for x in 0..<width {
            let start = x * samplesPerPixel
            let end = min(start + samplesPerPixel, total)
            guard start < end else { continue }
            let bucket = samples[start..<end]
            let minSample = bucket.min() ?? 0
            let maxSample = bucket.max() ?? 0
            let yMin = midY - CGFloat(minSample) * midY
            let yMax = midY - CGFloat(maxSample) * midY
            let xpos = CGFloat(x) + 0.5
            path.move(to: CGPoint(x: xpos, y: yMin))
            path.addLine(to: CGPoint(x: xpos, y: yMax))
        }
        return path
    }
}
