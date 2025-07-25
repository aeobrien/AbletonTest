// WaveformMarkerGrouping.swift
// Full SwiftUI implementation – drop this file into a new Xcode SwiftUI project.
// It lets you import a WAV file, visualise its waveform, add markers (sample indices),
// box‑select regions by dragging to auto‑assign groups, and export the marker list.
// Every major part is commented so you can follow what each piece does.
//
// ──────────────────────────────────────────────────────────────────────────────
// MARK: ‑ Imports
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// ──────────────────────────────────────────────────────────────────────────────
// MARK: ‑ Data Types

/// A single marker anchored to a sample position in the audio file.
struct Marker: Identifiable, Hashable {
    let id = UUID()
    let samplePosition: Int          // Exact sample index in the original file
    var group: Int? = nil            // Optional group number, assigned via drag‑selection
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: ‑ View‑Model (business logic)

/// Observable object that loads audio, down‑samples for drawing, manages markers & selection.
@MainActor
final class AudioViewModel: ObservableObject {
    // Publicly observed properties for the UI
    @Published var displaySamples: [Float] = []    // Down‑sampled amplitudes (|0…1|)
    @Published var markers: [Marker] = []          // All current markers
    @Published var tempSelection: ClosedRange<Int>? = nil // Live drag‑selection (sample indices)
    @Published var showImporter = false            // Triggers the FileImporter sheet

    // Internal bookkeeping
    private(set) var totalSamples: Int = 0         // True length of the WAV in samples
    private var audioURL: URL?                     // Keeps the imported file handy (future features)

    // MARK: Import WAV
    /// Reads a WAV file, converts to floats, and down‑samples for on‑screen drawing.
    func importWAV(from url: URL) {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            totalSamples = Int(file.length)

            // Pull the whole file into a buffer (mono‑only here for simplicity)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalSamples)) else { return }
            try file.read(into: buffer)
            guard let channelData = buffer.floatChannelData?[0] else { return }

            // Down‑sample to ~5 000 points for efficient drawing (adjust as you wish)
            let points = 5_000
            let step = max(1, totalSamples / points)           // «step» avoids shadowing Swift.stride()
            displaySamples = stride(from: 0, to: totalSamples, by: step).map { abs(channelData[$0]) }

            // Reset state
            markers.removeAll()
            tempSelection = nil
            audioURL = url
        } catch {
            print("Audio import failed: \(error.localizedDescription)")
        }
    }

    // MARK: Marker helpers
    /// Converts an x‑coordinate in the waveform view to a sample index.
    func sampleIndex(for x: CGFloat, width: CGFloat) -> Int {
        guard totalSamples > 0 else { return 0 }
        return min(max(Int((x / width) * CGFloat(totalSamples)), 0), totalSamples - 1)
    }

    /// Adds a marker at the tapped horizontal position.
    func addMarker(atX x: CGFloat, inWidth width: CGFloat) {
        let sample = sampleIndex(for: x, width: width)
        markers.append(Marker(samplePosition: sample))
    }

    // MARK: Drag‑selection helpers
    /// Updates the temporary selection during a drag gesture.
    func updateTempSelection(startX: CGFloat, currentX: CGFloat, width: CGFloat) {
        let startSample = sampleIndex(for: startX, width: width)
        let currentSample = sampleIndex(for: currentX, width: width)
        tempSelection = min(startSample, currentSample)...max(startSample, currentSample)
    }

    /// Finalises the selection: assigns all enclosed markers to a new group number.
    func commitSelection() {
        guard let range = tempSelection else { return }
        let newGroup = (markers.compactMap { $0.group }.max() ?? 0) + 1
        for i in markers.indices where range.contains(markers[i].samplePosition) {
            markers[i].group = newGroup
        }
        tempSelection = nil
    }

    // MARK: Export
    /// Serialises markers to pretty‑printed JSON (extend to file export if required).
    func exportMarkersJSON() -> String? {
        let payload = markers.map { ["sample": $0.samplePosition, "group": $0.group ?? 0] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: ‑ Waveform Drawing View

/// Renders the waveform, markers, and live selection overlay.
struct WaveformView: View {
    // Data inputs
    let samples: [Float]
    let totalSamples: Int
    @Binding var markers: [Marker]
    @Binding var selection: ClosedRange<Int>?

    // Callbacks to the view‑model
    let tapAction: (CGFloat, CGFloat) -> Void              // (x, width) → add marker
    let dragUpdate: (CGFloat, CGFloat, CGFloat) -> Void    // (startX, currentX, width) → update sel.
    let dragEnd: () -> Void                                // commit selection

    // The body draws with Canvas and overlays a gesture‑aware transparent layer.
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            Canvas { context, size in
                guard !samples.isEmpty else { return }
                let midY = size.height / 2
                let step = size.width / CGFloat(samples.count - 1)

                // Waveform path (simple vertical line peak representation)
                var path = Path()
                for i in samples.indices {
                    let x = CGFloat(i) * step
                    let y = CGFloat(samples[i]) * midY
                    path.move(to: CGPoint(x: x, y: midY - y))
                    path.addLine(to: CGPoint(x: x, y: midY + y))
                }
                context.stroke(path, with: .color(.accentColor), lineWidth: 1)

                // Draw existing markers
                for marker in markers {
                    let x = CGFloat(marker.samplePosition) / CGFloat(totalSamples) * size.width
                    var markerLine = Path()
                    markerLine.move(to: CGPoint(x: x, y: 0))
                    markerLine.addLine(to: CGPoint(x: x, y: size.height))
                    let colour: Color = marker.group == nil ? .red : .green
                    context.stroke(markerLine, with: .color(colour), lineWidth: 1)

                    // Tiny group label
                    if let group = marker.group {
                        let text = Text("\(group)").font(.caption2).foregroundColor(colour)
                        context.draw(text, at: CGPoint(x: x + 4, y: 10))
                    }
                }

                // Live selection rectangle
                if let sel = selection {
                    let xStart = CGFloat(sel.lowerBound) / CGFloat(totalSamples) * size.width
                    let xEnd   = CGFloat(sel.upperBound) / CGFloat(totalSamples) * size.width
                    let rect = CGRect(x: xStart, y: 0, width: xEnd - xStart, height: size.height)
                    context.fill(Path(rect), with: .color(Color.blue.opacity(0.2)))
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Treat near‑static drags as taps (to get location in TapGesture SwiftUI 3‑)
                        dragUpdate(value.startLocation.x, value.location.x, width)
                    }
                    .onEnded { value in
                        if abs(value.translation.width) < 3 { // ≈ stationary → add marker
                            tapAction(value.location.x, width)
                        } else {
                            dragEnd()
                        }
                    }
            )
        }
        .frame(height: 200)   // Fixed height – adjust or make configurable
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: ‑ Main Content View

struct ContentView: View {
    @State private var showTestView = false
    
    var body: some View {
        if showTestView {
            VStack {
                TestButtonView()
                Button("Back to Main View") {
                    showTestView = false
                }
                .padding()
            }
        } else {
            VStack {
                // Use the enhanced version with zooming, scrolling, and GPU acceleration
                EnhancedContentView()
                
                Button("Show Test View") {
                    showTestView = true
                }
                .padding()
            }
        }
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: ‑ App Entry Point

@main
struct MarkerGroupingApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
