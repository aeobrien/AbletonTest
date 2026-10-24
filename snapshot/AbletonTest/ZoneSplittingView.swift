import SwiftUI
import AVFoundation

struct ZoneSplittingView: View {
    let audioURL: URL
    let onComplete: ([ZoneMarker], Set<Int>) -> Void
    @Environment(\.dismiss) var dismiss
    
    @State private var sampleBuffer: SampleBuffer?
    @State private var totalSamples: Int = 0
    @State private var sampleRate: Double = 44100.0
    @State private var zoneMarkers: [ZoneMarker] = []
    @State private var isPlaying = false
    @State private var playheadPosition: Double = 0
    @State private var playbackTimer: Timer?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var zoomLevel: Double = 1.0
    @State private var scrollOffset: Double = 0
    @State private var isDraggingPlayhead = false
    @State private var ignoredZones: Set<Int> = []
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Split Audio into Zones")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(Color.gray.opacity(0.05))
            
            // Instructions
            Text("⌘+Click to add zone markers. Click to move the playhead. ⌘+Click on a marker to remove it.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)
            
            // Waveform view
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    // Waveform
                    if let buffer = sampleBuffer {
                        WaveformShape(
                            sampleBuffer: buffer,
                            zoomLevel: zoomLevel,
                            scrollOffset: scrollOffset,
                            color: .blue.opacity(0.7)
                        )
                        .frame(width: geometry.size.width * zoomLevel, height: geometry.size.height)
                        .offset(x: -scrollOffset * geometry.size.width)
                        
                        // Zone regions
                        ForEach(Array(zoneRegions.enumerated()), id: \.offset) { index, region in
                            Rectangle()
                                .fill(ignoredZones.contains(index) ? 
                                    Color.gray.opacity(0.2) :
                                    (index % 2 == 0 ? Color.green.opacity(0.1) : Color.orange.opacity(0.1)))
                                .frame(width: (region.end - region.start) * geometry.size.width * zoomLevel / Double(totalSamples))
                                .offset(x: region.start * geometry.size.width * zoomLevel / Double(totalSamples) - scrollOffset * geometry.size.width)
                        }
                        
                        // Zone markers
                        ForEach(zoneMarkers) { marker in
                            let x = marker.position * geometry.size.width * zoomLevel - scrollOffset * geometry.size.width
                            
                            if x >= -10 && x <= geometry.size.width + 10 {
                                ZoneMarkerView(
                                    marker: marker,
                                    x: x,
                                    height: geometry.size.height,
                                    geometry: geometry,
                                    zoomLevel: zoomLevel,
                                    scrollOffset: scrollOffset,
                                    onRemove: { removeMarker(marker) },
                                    onPositionChange: { newPosition in
                                        updateMarkerPosition(marker, to: newPosition)
                                    }
                                )
                            }
                        }
                        
                        // Playhead
                        let playheadX = playheadPosition * geometry.size.width * zoomLevel - scrollOffset * geometry.size.width
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 1, height: geometry.size.height)
                            .offset(x: playheadX)
                            .shadow(radius: 2)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    if !isDraggingPlayhead {
                        // Check for command modifier
                        if NSEvent.modifierFlags.contains(.command) {
                            // Command+Click adds a marker
                            let normalizedPosition = (location.x + scrollOffset * geometry.size.width) / (geometry.size.width * zoomLevel)
                            addMarker(at: normalizedPosition)
                        } else {
                            // Regular click moves playhead
                            let normalizedPosition = (location.x + scrollOffset * geometry.size.width) / (geometry.size.width * zoomLevel)
                            playheadPosition = max(0, min(1, normalizedPosition))
                            seekToPosition(playheadPosition)
                        }
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { value in
                            isDraggingPlayhead = true
                            let normalizedPosition = (value.location.x + scrollOffset * geometry.size.width) / (geometry.size.width * zoomLevel)
                            playheadPosition = max(0, min(1, normalizedPosition))
                            seekToPosition(playheadPosition)
                        }
                        .onEnded { _ in
                            isDraggingPlayhead = false
                        }
                )
            }
            .frame(height: 200)
            .background(Color.black)
            .clipped()
            
            // Zone labels
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    ForEach(Array(zoneRegions.enumerated()), id: \.offset) { index, region in
                        let startX = region.start * geometry.size.width * zoomLevel / Double(totalSamples) - scrollOffset * geometry.size.width
                        let width = (region.end - region.start) * geometry.size.width * zoomLevel / Double(totalSamples)
                        let centerX = startX + width / 2
                        
                        if centerX > -100 && centerX < geometry.size.width + 100 {
                            Text(ignoredZones.contains(index) ? "Zone \(index + 1) (Ignored)" : "Zone \(index + 1)")
                                .font(.caption2)
                                .foregroundColor(ignoredZones.contains(index) ? .gray : (index % 2 == 0 ? .green : .orange))
                                .frame(width: max(50, width))
                                .offset(x: startX)
                        }
                    }
                }
            }
            .frame(height: 20)
            .background(Color.gray.opacity(0.1))
            
            // Transport controls
            HStack(spacing: 20) {
                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                }
                .buttonStyle(.plain)
                
                Button(action: stopPlayback) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 36))
                }
                .buttonStyle(.plain)
                .disabled(!isPlaying)
                
                Spacer()
                
                // Zone info
                Text("\(zoneRegions.count) zone\(zoneRegions.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                // Zoom controls
                HStack {
                    Text("Zoom:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Slider(value: $zoomLevel, in: 1...10)
                        .frame(width: 100)
                    
                    Text(String(format: "%.1fx", zoomLevel))
                        .font(.caption)
                        .frame(width: 35)
                }
            }
            .padding()
            
            // Zone list
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(zoneRegions.enumerated()), id: \.offset) { index, region in
                        HStack {
                            Circle()
                                .fill(ignoredZones.contains(index) ? Color.gray : (index % 2 == 0 ? Color.green : Color.orange))
                                .frame(width: 12, height: 12)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Zone \(index + 1)")
                                    .font(.caption)
                                    .foregroundColor(ignoredZones.contains(index) ? .secondary : .primary)
                                
                                Text(formatTime(region.start / Double(totalSamples) * duration) + " - " + formatTime(region.end / Double(totalSamples) * duration))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Toggle("", isOn: Binding(
                                get: { !ignoredZones.contains(index) },
                                set: { include in
                                    if include {
                                        ignoredZones.remove(index)
                                    } else {
                                        ignoredZones.insert(index)
                                    }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .help(ignoredZones.contains(index) ? "Include zone" : "Ignore zone")
                            
                            Button(action: {
                                playZone(region)
                            }) {
                                Image(systemName: "play.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .disabled(ignoredZones.contains(index))
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                        .background(ignoredZones.contains(index) ? Color.gray.opacity(0.1) : Color.gray.opacity(0.05))
                        .cornerRadius(4)
                    }
                }
                .padding()
            }
            .frame(maxHeight: 150)
            
            // Bottom buttons
            HStack {
                Button("Use Whole File") {
                    onComplete([], Set())
                    dismiss()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Clear All Markers") {
                    zoneMarkers.removeAll()
                    ignoredZones.removeAll()
                }
                .foregroundColor(.red)
                .disabled(zoneMarkers.isEmpty)
                
                Spacer()
                
                Button("Split into Zones") {
                    onComplete(zoneMarkers, ignoredZones)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(zoneMarkers.isEmpty)
            }
            .padding()
        }
        .frame(width: 800, height: 600)
        .onAppear {
            loadAudioFile()
        }
        .onDisappear {
            stopPlayback()
            playbackTimer?.invalidate()
        }
    }
    
    // Computed properties
    var duration: Double {
        Double(totalSamples) / sampleRate
    }
    
    var zoneRegions: [(start: Double, end: Double)] {
        var regions: [(start: Double, end: Double)] = []
        let sortedMarkers = zoneMarkers.sorted { $0.position < $1.position }
        
        var start: Double = 0
        for marker in sortedMarkers {
            let markerSample = marker.position * Double(totalSamples)
            if markerSample > start {
                regions.append((start: start, end: markerSample))
            }
            start = markerSample
        }
        
        // Add final region
        if start < Double(totalSamples) {
            regions.append((start: start, end: Double(totalSamples)))
        }
        
        return regions
    }
    
    // Methods
    private func loadAudioFile() {
        do {
            let file = try AVAudioFile(forReading: audioURL)
            totalSamples = Int(file.length)
            sampleRate = file.fileFormat.sampleRate
            
            // Create sample buffer for waveform display
            let format = file.processingFormat
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalSamples)) else { return }
            try file.read(into: buffer)
            
            if let channelData = buffer.floatChannelData {
                var samples: [Float] = []
                let channelCount = Int(format.channelCount)
                let frameLength = Int(buffer.frameLength)
                
                // Mix down to mono if needed
                for frame in 0..<frameLength {
                    var sum: Float = 0
                    for channel in 0..<channelCount {
                        sum += channelData[channel][frame]
                    }
                    samples.append(sum / Float(channelCount))
                }
                
                sampleBuffer = SampleBuffer(samples: samples)
            }
            
            // Prepare audio player
            audioPlayer = try AVAudioPlayer(contentsOf: audioURL)
            audioPlayer?.prepareToPlay()
            
        } catch {
            print("Error loading audio file: \(error)")
        }
    }
    
    private func addMarker(at position: Double) {
        let newMarker = ZoneMarker(position: position)
        zoneMarkers.append(newMarker)
    }
    
    private func removeMarker(_ marker: ZoneMarker) {
        zoneMarkers.removeAll { $0.id == marker.id }
    }
    
    private func updateMarkerPosition(_ marker: ZoneMarker, to newPosition: Double) {
        if let index = zoneMarkers.firstIndex(where: { $0.id == marker.id }) {
            zoneMarkers[index].position = max(0, min(1, newPosition))
        }
    }
    
    private func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            startPlayback()
        }
    }
    
    private func startPlayback() {
        guard let player = audioPlayer else { return }
        
        player.currentTime = playheadPosition * duration
        player.play()
        isPlaying = true
        
        // Start playhead update timer
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            updatePlayhead()
        }
    }
    
    private func pausePlayback() {
        audioPlayer?.pause()
        isPlaying = false
        playbackTimer?.invalidate()
    }
    
    private func stopPlayback() {
        audioPlayer?.stop()
        isPlaying = false
        playheadPosition = 0
        playbackTimer?.invalidate()
    }
    
    private func seekToPosition(_ position: Double) {
        if let player = audioPlayer {
            player.currentTime = position * duration
            if !isPlaying {
                // Update UI even when not playing
                playheadPosition = position
            }
        }
    }
    
    private func updatePlayhead() {
        guard let player = audioPlayer, isPlaying else { return }
        
        playheadPosition = player.currentTime / duration
        
        // Stop if reached end
        if playheadPosition >= 1.0 {
            stopPlayback()
        }
    }
    
    private func playZone(_ zone: (start: Double, end: Double)) {
        stopPlayback()
        playheadPosition = zone.start / Double(totalSamples)
        startPlayback()
        
        // Set timer to stop at zone end
        let zoneDuration = (zone.end - zone.start) / sampleRate
        DispatchQueue.main.asyncAfter(deadline: .now() + zoneDuration) {
            if isPlaying {
                pausePlayback()
            }
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let millis = Int((seconds - Double(Int(seconds))) * 100)
        return String(format: "%d:%02d.%02d", minutes, secs, millis)
    }
}

// Zone marker model
struct ZoneMarker: Identifiable {
    let id = UUID()
    var position: Double // 0.0 to 1.0 normalized position
}

// Zone marker view with drag functionality
struct ZoneMarkerView: View {
    let marker: ZoneMarker
    let x: CGFloat
    let height: CGFloat
    let geometry: GeometryProxy
    let zoomLevel: Double
    let scrollOffset: Double
    let onRemove: () -> Void
    let onPositionChange: (Double) -> Void
    
    @State private var isDragging = false
    @State private var dragStartX: CGFloat = 0
    @State private var dragStartPosition: Double = 0
    @State private var translationBaseline: CGFloat = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // Marker handle at top
            Circle()
                .fill(Color.red)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.white, lineWidth: 1))
                .position(x: 6, y: 6)
                .frame(width: 12, height: 12)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if NSEvent.modifierFlags.contains(.command) { return }
                            
                            if !isDragging {
                                isDragging = true
                                dragStartX = x // screen-space marker x at drag start
                                dragStartPosition = marker.position
                            }
                            
                            // 1) Compute current screen-space x for the marker handle
                            let newScreenX = dragStartX + value.translation.width
                            
                            // 2) Convert to normalised position using the same mapping used for drawing:
                            // position → x_screen = position * (width * zoomLevel) - scrollOffset * width
                            let width = geometry.size.width
                            let newPosition = (newScreenX + scrollOffset * width) / (width * zoomLevel)
                            
                            onPositionChange(max(0, min(1, newPosition)))
                        }
                        .onEnded { _ in
                            isDragging = false
                            dragStartX = 0
                            dragStartPosition = 0
                            translationBaseline = 0
                        }
                )
                .simultaneousGesture(
                    TapGesture()
                        .modifiers(.command)
                        .onEnded {
                            onRemove()
                        }
                )
            
            // Marker line
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: height)
        }
        .offset(x: x - 1, y: -6)
    }
}

// Simple waveform shape for zone splitting view
struct WaveformShape: View {
    let sampleBuffer: SampleBuffer
    let zoomLevel: Double
    let scrollOffset: Double
    let color: Color
    
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                let midY = height / 2
                
                let samplesPerPixel = max(1, Int(Double(sampleBuffer.count) / (width * zoomLevel)))
                let startSample = Int(scrollOffset * Double(sampleBuffer.count))
                
                for x in 0..<Int(width) {
                    let sampleIndex = startSample + x * samplesPerPixel
                    guard sampleIndex < sampleBuffer.count else { break }
                    
                    // Get min/max for this pixel
                    var minValue: Float = 0
                    var maxValue: Float = 0
                    
                    for i in 0..<samplesPerPixel {
                        let idx = sampleIndex + i
                        if idx < sampleBuffer.count {
                            let value = sampleBuffer.samples[idx]
                            minValue = min(minValue, value)
                            maxValue = max(maxValue, value)
                        }
                    }
                    
                    let minY = midY + CGFloat(minValue) * midY
                    let maxY = midY + CGFloat(maxValue) * midY
                    
                    if x == 0 {
                        path.move(to: CGPoint(x: CGFloat(x), y: midY))
                    }
                    
                    path.addLine(to: CGPoint(x: CGFloat(x), y: minY))
                    path.addLine(to: CGPoint(x: CGFloat(x), y: maxY))
                }
            }
            .stroke(color, lineWidth: 1)
        }
    }
}