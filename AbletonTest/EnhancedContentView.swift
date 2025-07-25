import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Enhanced View Model with AudioKit Waveform support
@MainActor
final class EnhancedAudioViewModel: ObservableObject {
    // Audio data
    @Published var sampleBuffer: SampleBuffer?
    @Published var totalSamples: Int = 0
    
    // Markers and selection
    @Published var markers: [Marker] = []
    @Published var tempSelection: ClosedRange<Int>? = nil
    
    // View controls
    @Published var showImporter = false
    @Published var zoomLevel: Double = 1.0
    @Published var scrollOffset: Double = 0.0
    @Published var yScale: Double = 1.0
    
    // Transient detection
    @Published var transientThreshold: Double = 0.3
    @Published var transientMarkers: Set<Int> = []
    var hasDetectedTransients = false
    
    // Computed properties for visible range
    var visibleStart: Int {
        let start = Int(scrollOffset * Double(totalSamples))
        return min(max(0, start), totalSamples - 1)
    }
    
    var visibleLength: Int {
        let length = Int(Double(totalSamples) / zoomLevel)
        return min(length, totalSamples - visibleStart)
    }
    
    private var audioURL: URL?
    
    // MARK: Import WAV with AudioKit approach
    func importWAV(from url: URL) {
        do {
            let file = try AVAudioFile(forReading: url)
            totalSamples = Int(file.length)
            
            // Get float channel data using AudioKit's approach
            if let channelData = file.floatChannelData() {
                // Use first channel for mono or left channel for stereo
                let samples = channelData[0]
                sampleBuffer = SampleBuffer(samples: samples)
                
                // Reset state
                markers.removeAll()
                tempSelection = nil
                audioURL = url
                
                // Reset view controls
                zoomLevel = 1.0
                scrollOffset = 0.0
                
                // Auto-scale Y axis based on peak amplitude
                let maxAmplitude = samples.map { abs($0) }.max() ?? 1.0
                if maxAmplitude > 0 {
                    // Scale so that the loudest part uses ~90% of the height
                    yScale = Double(0.9 / maxAmplitude)
                } else {
                    yScale = 1.0
                }
            }
        } catch {
            print("Audio import failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: Coordinate conversion helpers
    func sampleIndex(for x: CGFloat, in width: CGFloat) -> Int {
        guard totalSamples > 0 else { return 0 }
        let normalizedX = x / width
        let sampleInView = Int(normalizedX * Double(visibleLength))
        let absoluteSample = visibleStart + sampleInView
        return min(max(absoluteSample, 0), totalSamples - 1)
    }
    
    func xPosition(for sampleIndex: Int, in width: CGFloat) -> CGFloat {
        guard visibleLength > 0 else { return 0 }
        let relativeSample = sampleIndex - visibleStart
        let normalizedPosition = Double(relativeSample) / Double(visibleLength)
        return CGFloat(normalizedPosition) * width
    }
    
    // MARK: Marker management
    func addMarker(atX x: CGFloat, inWidth width: CGFloat) {
        let sample = sampleIndex(for: x, in: width)
        markers.append(Marker(samplePosition: sample))
    }
    
    func updateTempSelection(startX: CGFloat, currentX: CGFloat, width: CGFloat) {
        let startSample = sampleIndex(for: startX, in: width)
        let currentSample = sampleIndex(for: currentX, in: width)
        tempSelection = min(startSample, currentSample)...max(startSample, currentSample)
    }
    
    func commitSelection() {
        guard let range = tempSelection else { return }
        let newGroup = (markers.compactMap { $0.group }.max() ?? 0) + 1
        for i in markers.indices where range.contains(markers[i].samplePosition) {
            markers[i].group = newGroup
        }
        tempSelection = nil
    }
    
    // MARK: Zoom and scroll helpers
    func zoom(by factor: Double, at location: CGFloat, in width: CGFloat) {
        let oldZoom = zoomLevel
        zoomLevel = max(1.0, min(500.0, zoomLevel * factor))  // Increased max zoom to 500x
        
        // Adjust scroll to keep the zoom point stationary
        if zoomLevel != oldZoom {
            let normalizedLocation = location / width
            let sampleAtLocation = visibleStart + Int(normalizedLocation * Double(visibleLength))
            
            let newVisibleLength = Double(totalSamples) / zoomLevel
            let newStart = Double(sampleAtLocation) - normalizedLocation * newVisibleLength
            scrollOffset = max(0, min(1 - 1/zoomLevel, newStart / Double(totalSamples)))
        }
    }
    
    func scroll(by delta: Double) {
        scrollOffset = max(0, min(1 - 1/zoomLevel, scrollOffset + delta))
    }
    
    // MARK: Export
    func exportMarkersJSON() -> String? {
        let payload = markers.map { ["sample": $0.samplePosition, "group": $0.group ?? 0] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    // MARK: Transient Detection
    func detectTransients() {
        print("=== TRANSIENT DETECTION START ===")
        guard let buffer = sampleBuffer else { 
            print("No sample buffer available")
            return 
        }
        
        transientMarkers.removeAll()
        let samples = buffer.samples
        print("Total samples: \(samples.count)")
        guard samples.count > 10 else { 
            print("Not enough samples")
            return 
        }
        
        // Use larger window for better transient detection
        let windowSize = 2048
        let hopSize = windowSize / 2
        let windowCount = (samples.count - windowSize) / hopSize + 1
        
        var energyValues: [Float] = []
        
        // Calculate energy for each window
        for i in 0..<windowCount {
            let startIdx = i * hopSize
            let endIdx = min(startIdx + windowSize, samples.count)
            
            if endIdx > startIdx {
                let window = Array(samples[startIdx..<endIdx])
                let energy = window.reduce(0.0) { $0 + abs($1) } / Float(window.count)
                energyValues.append(energy)
            }
        }
        
        print("Calculated \(energyValues.count) energy windows")
        
        // Find peaks in energy that indicate transients
        var detectedTransients: Set<Int> = []
        let minSpacing = 44100 / 4 // Minimum 0.25 seconds between transients
        
        if energyValues.count > 2 {
            // Calculate mean and standard deviation
            let mean = energyValues.reduce(0, +) / Float(energyValues.count)
            let variance = energyValues.map { pow($0 - mean, 2) }.reduce(0, +) / Float(energyValues.count)
            let stdDev = sqrt(variance)
            
            // Threshold based on mean + (threshold * stdDev)
            let detectionThreshold = mean + Float(transientThreshold * 3) * stdDev
            
            print("Energy stats - Mean: \(mean), StdDev: \(stdDev), Threshold: \(detectionThreshold)")
            
            var lastTransientSample = -minSpacing
            
            for i in 1..<(energyValues.count - 1) {
                let prev = energyValues[i - 1]
                let curr = energyValues[i]
                let next = energyValues[i + 1]
                
                // Check if this is a local peak above threshold
                if curr > prev && curr > next && curr > detectionThreshold {
                    let samplePosition = i * hopSize
                    
                    // Check minimum spacing
                    if samplePosition - lastTransientSample >= minSpacing {
                        detectedTransients.insert(samplePosition)
                        lastTransientSample = samplePosition
                        
                        if detectedTransients.count <= 10 {
                            print("Transient at window \(i) -> sample \(samplePosition) (energy: \(curr))")
                        }
                    }
                }
            }
        }
        
        transientMarkers = detectedTransients
        hasDetectedTransients = true
        
        print("Detected \(detectedTransients.count) transients with threshold \(transientThreshold)")
        print("=== TRANSIENT DETECTION END ===")
        
        // Update markers to include transients
        updateMarkersWithTransients()
    }
    
    
    func updateMarkersWithTransients() {
        // Remove existing transient markers (those without groups)
        markers.removeAll { marker in
            marker.group == nil && transientMarkers.contains(marker.samplePosition)
        }
        
        // Add new transient markers
        for samplePos in transientMarkers {
            if !markers.contains(where: { $0.samplePosition == samplePos }) {
                markers.append(Marker(samplePosition: samplePos))
            }
        }
        
        // Sort markers by position
        markers.sort { $0.samplePosition < $1.samplePosition }
    }
    
    func updateTransientThreshold(_ newThreshold: Double) {
        print("Threshold slider changed to: \(newThreshold)")
        transientThreshold = newThreshold
        if hasDetectedTransients {
            print("Re-detecting transients with new threshold")
            detectTransients()
        } else {
            print("First threshold change - triggering initial detection")
            hasDetectedTransients = true
            detectTransients()
        }
    }
}

// MARK: - Enhanced Waveform View with markers and selection
struct EnhancedWaveformView: View {
    @ObservedObject var viewModel: EnhancedAudioViewModel
    let height: CGFloat = 400  // Doubled height
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                
                // Clipped content area
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.clear)
                    .clipped()
                    .overlay(
                        ZStack {
                            // AudioKit Waveform (GPU accelerated)
                            if let buffer = viewModel.sampleBuffer {
                                Waveform(
                                    samples: buffer,
                                    start: viewModel.visibleStart,
                                    length: viewModel.visibleLength
                                )
                                .foregroundColor(.blue)
                                .scaleEffect(y: CGFloat(viewModel.yScale))
                            }
                            
                            // Markers overlay
                            Canvas { context, size in
                                // Draw markers
                                for marker in viewModel.markers {
                                    let x = viewModel.xPosition(for: marker.samplePosition, in: size.width)
                                    
                                    // Only draw if marker is visible
                                    if x >= 0 && x <= size.width {
                                        var markerLine = Path()
                                        markerLine.move(to: CGPoint(x: x, y: 0))
                                        markerLine.addLine(to: CGPoint(x: x, y: size.height))
                                        
                                        let color: Color = marker.group == nil ? .red : .green
                                        context.stroke(markerLine, with: .color(color), lineWidth: 2)
                                        
                                        // Group label
                                        if let group = marker.group {
                                            let text = Text("\(group)")
                                                .font(.caption)
                                                .foregroundColor(.white)
                                            
                                            // Draw background for label
                                            let textSize = CGSize(width: 20, height: 16)
                                            let labelRect = CGRect(x: x + 4, y: 12, width: textSize.width, height: textSize.height)
                                            context.fill(Path(roundedRect: labelRect, cornerRadius: 4), with: .color(color))
                                            context.draw(text, at: CGPoint(x: x + 14, y: 20))
                                        }
                                    }
                                }
                                
                                // Selection rectangle
                                if let selection = viewModel.tempSelection {
                                    let xStart = viewModel.xPosition(for: selection.lowerBound, in: size.width)
                                    let xEnd = viewModel.xPosition(for: selection.upperBound, in: size.width)
                                    
                                    if xEnd > 0 && xStart < size.width {
                                        let rect = CGRect(
                                            x: max(0, xStart),
                                            y: 0,
                                            width: min(size.width, xEnd) - max(0, xStart),
                                            height: size.height
                                        )
                                        context.fill(Path(rect), with: .color(Color.blue.opacity(0.2)))
                                        context.stroke(Path(rect), with: .color(Color.blue.opacity(0.5)), lineWidth: 1)
                                    }
                                }
                            }
                            .allowsHitTesting(false)
                        }
                        .clipped()
                    )
                
                // Interaction layer
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                viewModel.updateTempSelection(
                                    startX: value.startLocation.x,
                                    currentX: value.location.x,
                                    width: geometry.size.width
                                )
                            }
                            .onEnded { value in
                                if abs(value.translation.width) < 5 {
                                    viewModel.addMarker(atX: value.location.x, inWidth: geometry.size.width)
                                } else {
                                    viewModel.commitSelection()
                                }
                            }
                    )
                    .onTapGesture { location in
                        viewModel.addMarker(atX: location.x, inWidth: geometry.size.width)
                    }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Minimap for navigation
struct MinimapView: View {
    @ObservedObject var viewModel: EnhancedAudioViewModel
    @State private var debugLastEvent = "None"
    @State private var debugEventCount = 0
    
    var body: some View {
        ZStack {
            GeometryReader { geometry in
                // Debug info overlay
                DebugOverlay(lastEvent: $debugLastEvent, eventCount: $debugEventCount)
                    .position(x: 50, y: 20)
                    .zIndex(100)
                // Waveform preview
                if let buffer = viewModel.sampleBuffer {
                    Waveform(samples: buffer)
                        .foregroundColor(.gray.opacity(0.5))
                        .allowsHitTesting(false)
                }
                
                // Interactive overlay for gestures
                Color.clear
                    .contentShape(Rectangle())
                    .debugInteractions("Minimap", lastEvent: $debugLastEvent, eventCount: $debugEventCount)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                debugLastEvent = "Minimap drag at \(Int(value.location.x))"
                                debugEventCount += 1
                                print(">>> MINIMAP DRAG at: \(value.location) <<<")
                                guard viewModel.zoomLevel > 1.0 else { return }
                                
                                let indicatorHalfWidth = geometry.size.width / CGFloat(viewModel.zoomLevel) / 2
                                let targetOffset = (value.location.x - indicatorHalfWidth) / geometry.size.width
                                viewModel.scrollOffset = max(0, min(1 - 1/viewModel.zoomLevel, Double(targetOffset)))
                            }
                            .onEnded { value in
                                if abs(value.translation.width) < 3 {
                                    debugLastEvent = "Minimap tap at \(Int(value.location.x))"
                                    debugEventCount += 1
                                    print(">>> MINIMAP TAP at: \(value.location) <<<")
                                    guard viewModel.zoomLevel > 1.0 else {
                                        print("Not zoomed in, zoom level: \(viewModel.zoomLevel)")
                                        return
                                    }
                                    
                                    let indicatorHalfWidth = geometry.size.width / CGFloat(viewModel.zoomLevel) / 2
                                    let targetOffset = (value.location.x - indicatorHalfWidth) / geometry.size.width
                                    let clampedOffset = max(0, min(1 - 1/viewModel.zoomLevel, Double(targetOffset)))
                                    print("Setting scroll offset to: \(clampedOffset)")
                                    viewModel.scrollOffset = clampedOffset
                                }
                            }
                    )
                
                // Visible area indicator (non-interactive)
                let indicatorWidth = max(20, geometry.size.width / CGFloat(viewModel.zoomLevel))
                let indicatorOffset = CGFloat(viewModel.scrollOffset) * geometry.size.width
                
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.blue.opacity(0.3))
                    .stroke(Color.blue, lineWidth: 1)
                    .frame(width: indicatorWidth, height: geometry.size.height - 4)
                    .offset(x: indicatorOffset)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 60)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Control panel for zoom and Y-scale
struct WaveformControls: View {
    @ObservedObject var viewModel: EnhancedAudioViewModel
    
    var body: some View {
        VStack(spacing: 12) {
            // Zoom controls
            HStack {
                Text("Zoom:")
                Slider(value: $viewModel.zoomLevel, in: 1...500)
                    .frame(width: 200)
                Text(String(format: "%.1fx", viewModel.zoomLevel))
                    .frame(width: 50)
            }
            
            // Y-scale controls
            HStack {
                Text("Y-Scale:")
                Slider(value: $viewModel.yScale, in: 0.01...20.0)
                    .frame(width: 200)
                Text(String(format: "%.1fx", viewModel.yScale))
                    .frame(width: 50)
            }
            
            // Transient threshold controls
            HStack {
                Text("Transient Threshold:")
                Slider(
                    value: Binding(
                        get: { viewModel.transientThreshold },
                        set: { viewModel.updateTransientThreshold($0) }
                    ),
                    in: 0.001...1.0
                )
                .frame(width: 200)
                .disabled(viewModel.sampleBuffer == nil)
                Text(String(format: "%.2f", viewModel.transientThreshold))
                    .frame(width: 50)
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Main enhanced view
struct EnhancedContentView: View {
    @StateObject private var viewModel = EnhancedAudioViewModel()
    
    var body: some View {
        VStack(spacing: 20) {
            // Header with title and import button
            HStack {
                Text("Waveform Marker Tool")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                // Simplified button approach
                Text("Detect Transients")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(viewModel.sampleBuffer == nil ? Color.gray : Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .onTapGesture {
                        guard viewModel.sampleBuffer != nil else { return }
                        print(">>> TRANSIENT BUTTON TAPPED <<<")
                        viewModel.detectTransients()
                    }
                
                Button(action: { viewModel.showImporter = true }) {
                    Label("Import WAV", systemImage: "waveform")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            
            // Minimap for navigation
            VStack(alignment: .leading, spacing: 4) {
                Text("Overview")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                
                MinimapView(viewModel: viewModel)
                    .padding(.horizontal)
            }
            
            // Main waveform with markers
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Waveform")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    if viewModel.totalSamples > 0 {
                        Text("Visible: \(viewModel.visibleStart)-\(viewModel.visibleStart + viewModel.visibleLength)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
                
                EnhancedWaveformView(viewModel: viewModel)
                    .padding(.horizontal)
            }
            
            // Controls
            WaveformControls(viewModel: viewModel)
                .padding(.vertical, 8)
                .background(Color.gray.opacity(0.05))
                .cornerRadius(8)
                .padding(.horizontal)
            
            // Marker list
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Markers (\(viewModel.markers.count))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    if !viewModel.markers.isEmpty {
                        Button("Clear All") {
                            viewModel.markers.removeAll()
                            viewModel.transientMarkers.removeAll()
                            viewModel.hasDetectedTransients = false
                        }
                        .font(.caption)
                        .foregroundColor(.red)
                    }
                }
                .padding(.horizontal)
                
                List(viewModel.markers) { marker in
                    HStack {
                        Circle()
                            .fill(marker.group == nil ? Color.red : Color.green)
                            .frame(width: 8, height: 8)
                        
                        Text("Sample: \(marker.samplePosition)")
                            .font(.system(.footnote, design: .monospaced))
                        
                        Spacer()
                        
                        if let group = marker.group {
                            Label("Group \(group)", systemImage: "folder")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                }
                .frame(maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
            }
            .padding(.horizontal)
            
            // Action buttons
            HStack(spacing: 16) {
                Button(action: {
                    viewModel.zoomLevel = 1.0
                    viewModel.scrollOffset = 0.0
                    viewModel.yScale = 1.0
                }) {
                    Label("Reset View", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(6)
                }
                
                Button(action: {
                    if let json = viewModel.exportMarkersJSON() {
                        print("Exported JSON:")
                        print(json)
                    }
                }) {
                    Label("Export JSON", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.1))
                        .foregroundColor(.accentColor)
                        .cornerRadius(6)
                }
            }
            .padding(.horizontal)
            
            Spacer()
        }
        .padding(.vertical)
        .fileImporter(
            isPresented: $viewModel.showImporter,
            allowedContentTypes: [.wav]
        ) { result in
            if case .success(let url) = result {
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    viewModel.importWAV(from: url)
                }
            }
        }
        .onKeyPress { key in
            switch key.key {
            case .leftArrow:
                viewModel.scroll(by: -0.05)
                return .handled
            case .rightArrow:
                viewModel.scroll(by: 0.05)
                return .handled
            case .upArrow:
                viewModel.zoom(by: 1.2, at: 0.5, in: 1.0)
                return .handled
            case .downArrow:
                viewModel.zoom(by: 0.8, at: 0.5, in: 1.0)
                return .handled
            default:
                return .ignored
            }
        }
    }
}
