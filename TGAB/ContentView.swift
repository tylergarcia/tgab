// MARK: – Main UI
import SwiftUI
import AVFoundation
import Combine

struct ContentView: View {
    @StateObject private var eng = ABEngine()
    @State private var zoomA: CGFloat = 1.0
    @State private var zoomB: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 18) {
            // Waveform displays with playhead and zoom controls
            HStack(spacing: 40) {
                // Track A
                VStack {
                    // Zoom slider for A
                    HStack {
                        Text("Zoom A")
                        Slider(value: $zoomA, in: 1...10)
                    }
                    WaveformView(path: eng.waveformPathA,
                                 zoom: zoomA,
                                 progress: eng.progress)
                        .frame(height: 80)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.black.opacity(0.2))
                        )
                }

                // Track B
                VStack {
                    HStack {
                        Text("Zoom B")
                        Slider(value: $zoomB, in: 1...10)
                    }
                    WaveformView(path: eng.waveformPathB,
                                 zoom: zoomB,
                                 progress: eng.progress)
                        .frame(height: 80)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.black.opacity(0.2))
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 8)

            // Meters + filenames
            HStack(spacing: 40) {
                meterColumn(side: .a, title: "A", leftLevel: eng.meterALeft, rightLevel: eng.meterARight,
                            filename: eng.fileAName,
                            gain: $eng.gainA,
                            color: .blue) {
                    eng.loadFile(side: .a)
                }
                meterColumn(side: .b, title: "B", leftLevel: eng.meterBLeft, rightLevel: eng.meterBRight,
                            filename: eng.fileBName,
                            gain: $eng.gainB,
                            color: .orange) {
                    eng.loadFile(side: .b)
                }
            }

            // Seekable progress slider
            Slider(value: $eng.progress, in: 0...1, onEditingChanged: { editing in
                if !editing {
                    eng.seek(to: eng.progress)
                }
            })
            .frame(width: 420)
            .padding(.vertical, 4)

            // Big A/B toggle button
            Button(action: {
                eng.active = (eng.active == .a) ? .b : .a
            }) {
                Text(eng.active == .a ? "A" : "B")
                    .font(.system(size: 32, weight: .bold))
                    .frame(width: 110, height: 110)
                    .background(Circle().strokeBorder(Color.primary, lineWidth: 2))
            }
            .padding(.top, 12)

            // Ballistics controls
            HStack {
                VStack {
                    Text("Attack: \(String(format: "%.2f", eng.attackTime))s")
                    Slider(value: $eng.attackTime, in: 0.001...0.1)
                }
                VStack {
                    Text("Release: \(String(format: "%.2f", eng.releaseTime))s")
                    Slider(value: $eng.releaseTime, in: 0.1...1.0)
                }
            }
            .padding()

            // Presets
            HStack {
                Picker("Preset", selection: $eng.presets) {
                    ForEach(eng.presets, id: \.self) {
                        Text($0)
                    }
                }
                Button("Save Preset") {
                    // Ideally show an alert to enter name; use a default
                    eng.savePreset(named: "Preset \(Date().timeIntervalSince1970)")
                }
                Button("Delete") {
                    if let name = eng.presets.first {
                        eng.deletePreset(named: name)
                    }
                }
            }
            .padding()

            // Transport
            HStack(spacing: 30) {
                Button(eng.isPlaying ? "Stop" : "Play") {
                    eng.isPlaying ? eng.stop() : eng.play()
                }
                .keyboardShortcut(.space, modifiers: [])
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(minWidth: 700, minHeight: 500)
    }

    // meter UI helper
    func meterColumn(side: ABEngine.ActiveSide,
                     title: String,
                     leftLevel: Float,
                     rightLevel: Float,
                     filename: String,
                     gain: Binding<Float>,
                     color: Color,
                     loadAction: @escaping ()->Void) -> some View {
        
        // compute normalized levels and colors
        let normL = max(0, min((leftLevel + 60)/60, 1))
        let normR = max(0, min((rightLevel + 60)/60, 1))
        func barColor(_ lvl: Float) -> Color {
            if lvl > -6 { return .orange }
            else if lvl > -24 { return .yellow }
            else { return .green }
        }

        return ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(eng.active == side
                      ? Color.green.opacity(0.15)
                      : Color.red.opacity(0.08))

            VStack {
                Text(title)
                    .font(.title3).bold()

                // Dynamic stereo bars with color zones
                ZStack(alignment: .bottom) {
                    // outline
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.secondary, lineWidth: 1)
                        .frame(width: 24, height: 160)

                    // left and right dynamic bars
                    HStack(alignment: .bottom, spacing: 4) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(barColor(leftLevel))
                            .frame(width: 10, height: CGFloat(normL)*160)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(barColor(rightLevel))
                            .frame(width: 10, height: CGFloat(normR)*160)
                    }
                }
                Text(String(format:"%.1f dB", max(leftLevel, rightLevel)))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.top, 2)

                // Gain slider
                Slider(value: gain, in: 0...1) { _ in }
                    .help("Gain")
                    .padding(.horizontal, 8)

                // current gain in dB
                Text(String(format: "%.1f dB", side == .a
                                         ? eng.gainADecibels
                                         : eng.gainBDecibels))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)

                // File load + name
                Button("Open…", action: loadAction)

                Text(filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: 160)
            }
            .padding(12)
        }
        .contentShape(Rectangle())
        .onTapGesture { eng.active = side }
    }
}

/// Renders a vector waveform path with zoom and centered playhead.
struct WaveformView: View {
    let path: CGPath?
    let zoom: CGFloat
    let progress: Double

    init(path: CGPath?, zoom: CGFloat, progress: Double) {
        self.path = path
        self.zoom = zoom
        self.progress = progress
    }

    /// Returns the transformed CGPath for the given drawing size.
    private func transformedPath(in size: CGSize) -> CGPath? {
        guard let cgPath = path else { return nil }
        let bbox = cgPath.boundingBox
        let scaleX = size.width * zoom / bbox.width
        let scaleY = size.height / bbox.height
        var transform = CGAffineTransform(translationX: -bbox.minX, y: -bbox.minY)
        transform = transform.scaledBy(x: scaleX, y: scaleY)
        return cgPath.copy(using: &transform)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let t = transformedPath(in: geo.size) {
                    Path(t)
                        .stroke(Color.secondary, lineWidth: 1)
                        .offset(x: geo.size.width/2 - CGFloat(progress) * geo.size.width * zoom)
                    
                    Path { p in
                        let centerX = geo.size.width / 2
                        p.move(to: CGPoint(x: centerX, y: 0))
                        p.addLine(to: CGPoint(x: centerX, y: geo.size.height))
                    }
                    .stroke(Color.blue.opacity(0.9), lineWidth: 1)
                } else {
                    EmptyView()
                }
            }
        }
        .clipped()
    }
}
