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
    @Published var draggingMarkerIndex: Int? = nil
    
    // View controls
    @Published var showImporter = false
    @Published var zoomLevel: Double = 1.0
    @Published var scrollOffset: Double = 0.0
    @Published var yScale: Double = 1.0
    
    // Group assignment controls
    @Published var autoAssignGroups = true
    @Published var showGroupAssignmentMenu = false
    @Published var pendingGroupAssignment: ClosedRange<Int>? = nil
    
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
    
    var audioURL: URL?
    var audioPlayer: AVAudioPlayer?  // Made public for SamplerViewModel access
    @Published var isPlaying = false
    @Published var playheadPosition: Double = 0.0 // Position in samples
    private var playbackTimer: Timer?
    
    // MARK: Import WAV with AudioKit approach
    func importWAV(from url: URL) {
        print("=== IMPORT WAV START ===")
        print("Attempting to import: \(url.absoluteString)")
        
        do {
            print("Creating AVAudioFile...")
            let file = try AVAudioFile(forReading: url)
            totalSamples = Int(file.length)
            print("File length: \(file.length) samples")
            print("Sample rate: \(file.fileFormat.sampleRate)")
            print("Channel count: \(file.fileFormat.channelCount)")
            
            // Get float channel data using AudioKit's approach
            print("Getting float channel data...")
            if let channelData = file.floatChannelData() {
                print("Successfully got channel data")
                // Use first channel for mono or left channel for stereo
                let samples = channelData[0]
                print("First channel has \(samples.count) samples")
                sampleBuffer = SampleBuffer(samples: samples)
                print("SampleBuffer created successfully")
                
                // Reset state
                markers.removeAll()
                tempSelection = nil
                audioURL = url
                
                // Reset view controls
                zoomLevel = 1.0
                scrollOffset = 0.0
                
                // Setup audio player
                setupAudioPlayer(url: url)
                
                // Auto-scale Y axis based on peak amplitude
                let maxAmplitude = samples.map { abs($0) }.max() ?? 1.0
                print("Max amplitude: \(maxAmplitude)")
                if maxAmplitude > 0 {
                    // Scale so that the loudest part uses ~90% of the height
                    yScale = Double(0.9 / maxAmplitude)
                } else {
                    yScale = 1.0
                }
                print("Y scale set to: \(yScale)")
                print("=== IMPORT WAV SUCCESS ===")
            } else {
                print("ERROR: Failed to get float channel data")
                print("=== IMPORT WAV FAILED ===")
            }
        } catch {
            print("ERROR: Audio import failed: \(error.localizedDescription)")
            print("Error details: \(error)")
            print("=== IMPORT WAV FAILED ===")
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
    
    func findMarkerNearPosition(x: CGFloat, width: CGFloat, tolerance: CGFloat = 10) -> Int? {
        for (index, marker) in markers.enumerated() {
            let markerX = xPosition(for: marker.samplePosition, in: width)
            if abs(markerX - x) <= tolerance {
                return index
            }
        }
        return nil
    }
    
    func moveMarker(at index: Int, toX x: CGFloat, width: CGFloat) {
        guard index >= 0 && index < markers.count else { return }
        let oldSamplePosition = markers[index].samplePosition
        let newSamplePosition = sampleIndex(for: x, in: width)
        
        // Update transientMarkers set if this is a transient marker
        if markers[index].group == nil {
            transientMarkers.remove(oldSamplePosition)
            transientMarkers.insert(newSamplePosition)
        }
        
        markers[index].samplePosition = newSamplePosition
    }
    
    func updateTempSelection(startX: CGFloat, currentX: CGFloat, width: CGFloat) {
        let startSample = sampleIndex(for: startX, in: width)
        let currentSample = sampleIndex(for: currentX, in: width)
        tempSelection = min(startSample, currentSample)...max(startSample, currentSample)
    }
    
    func commitSelection() {
        guard let range = tempSelection else { return }
        
        if autoAssignGroups {
            // Auto-assign to next available group
            let newGroup = (markers.compactMap { $0.group }.max() ?? 0) + 1
            for i in markers.indices where range.contains(markers[i].samplePosition) {
                markers[i].group = newGroup
            }
            // Keep selection visible for playback
            // tempSelection = nil  // Don't clear selection
        } else {
            // Store selection for manual assignment
            pendingGroupAssignment = range
            showGroupAssignmentMenu = true
        }
    }
    
    func clearSelection() {
        tempSelection = nil
        pendingGroupAssignment = nil
    }
    
    func assignToGroup(_ groupNumber: Int) {
        guard let range = pendingGroupAssignment else { return }
        for i in markers.indices where range.contains(markers[i].samplePosition) {
            markers[i].group = groupNumber
        }
        pendingGroupAssignment = nil
        tempSelection = nil
        showGroupAssignmentMenu = false
    }
    
    func assignIncrementally() {
        guard let range = pendingGroupAssignment else { return }
        let selectedMarkers = markers.enumerated()
            .filter { range.contains($0.element.samplePosition) }
            .sorted { $0.element.samplePosition < $1.element.samplePosition }
        
        var currentGroup = 1
        for (index, _) in selectedMarkers {
            markers[index].group = currentGroup
            currentGroup += 1
        }
        
        pendingGroupAssignment = nil
        tempSelection = nil
        showGroupAssignmentMenu = false
    }
    
    func unassignFromGroups() {
        guard let range = pendingGroupAssignment else { return }
        for i in markers.indices where range.contains(markers[i].samplePosition) {
            markers[i].group = nil
        }
        pendingGroupAssignment = nil
        tempSelection = nil
        showGroupAssignmentMenu = false
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
    
    // MARK: Audio Playback
    
    private func setupAudioPlayer(url: URL) {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
        } catch {
            print("Failed to setup audio player: \(error)")
        }
    }
    
    func playSelection() {
        guard let player = audioPlayer, let buffer = sampleBuffer else { return }
        
        if let selection = tempSelection ?? pendingGroupAssignment {
            // Play selected region
            let sampleRate = player.format.sampleRate
            let startTime = TimeInterval(selection.lowerBound) / sampleRate
            let endTime = TimeInterval(selection.upperBound) / sampleRate
            let duration = endTime - startTime
            
            // Stop any current playback
            player.stop()
            player.currentTime = startTime
            player.play()
            isPlaying = true
            
            // Start playhead tracking
            startPlayheadTracking()
            
            // Use a timer to stop at the exact end time
            Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
                if self.isPlaying {
                    player.pause()
                    self.isPlaying = false
                    self.stopPlayheadTracking()
                }
            }
        } else {
            // Play entire file
            togglePlayback()
        }
    }
    
    func togglePlayback() {
        guard let player = audioPlayer else { return }
        
        if isPlaying {
            player.pause()
            isPlaying = false
            stopPlayheadTracking()
        } else {
            player.play()
            isPlaying = true
            startPlayheadTracking()
        }
    }
    
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer?.currentTime = 0
        isPlaying = false
        playheadPosition = 0
        stopPlayheadTracking()
    }
    
    private func startPlayheadTracking() {
        stopPlayheadTracking() // Clear any existing timer
        
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            if let player = self.audioPlayer, let rate = self.sampleBuffer?.samples.count {
                let sampleRate = player.format.sampleRate
                self.playheadPosition = player.currentTime * sampleRate
            }
        }
    }
    
    private func stopPlayheadTracking() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
}

// MARK: - Enhanced Waveform View with markers and selection
struct EnhancedWaveformView: View {
    @ObservedObject var viewModel: EnhancedAudioViewModel
    let height: CGFloat = 400  // Doubled height
    
    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
            
            // Clipped content area with interaction
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.clear)
                .overlay(
                    GeometryReader { geometry in
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
                                .clipped() // Ensure scaling doesn't extend beyond bounds
                                .allowsHitTesting(false)
                            }
                            
                            // Markers and playhead overlay
                            Canvas { context, size in
                                // Draw playhead if playing
                                if viewModel.isPlaying {
                                    let playheadX = viewModel.xPosition(for: Int(viewModel.playheadPosition), in: size.width)
                                    if playheadX >= 0 && playheadX <= size.width {
                                        var playheadPath = Path()
                                        playheadPath.move(to: CGPoint(x: playheadX, y: 0))
                                        playheadPath.addLine(to: CGPoint(x: playheadX, y: size.height))
                                        context.stroke(playheadPath, with: .color(.orange), lineWidth: 2)
                                    }
                                }
                                
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
                                        
                                        // Draw handle for transient markers (red markers without groups)
                                        if marker.group == nil {
                                            let handleSize: CGFloat = 12
                                            let handleRect = CGRect(
                                                x: x - handleSize / 2,
                                                y: 0,
                                                width: handleSize,
                                                height: handleSize
                                            )
                                            context.fill(Path(ellipseIn: handleRect), with: .color(color))
                                            context.stroke(Path(ellipseIn: handleRect), with: .color(.white), lineWidth: 1)
                                        }
                                        
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
                            
                            // Interaction layer - re-enabled now that Y scale is fixed
                            Rectangle()
                                .fill(Color.clear)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { location in
                                    print("Double tap @ \(location.x)")
                                    // Check if we're near an existing marker
                                    if let markerIndex = viewModel.findMarkerNearPosition(x: location.x, width: geometry.size.width) {
                                        // Remove the marker
                                        let marker = viewModel.markers[markerIndex]
                                        if marker.group == nil {
                                            viewModel.transientMarkers.remove(marker.samplePosition)
                                        }
                                        viewModel.markers.remove(at: markerIndex)
                                    } else {
                                        // Add a new marker
                                        viewModel.addMarker(atX: location.x, inWidth: geometry.size.width)
                                    }
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            // Check if we started dragging near a marker handle
                                            if viewModel.draggingMarkerIndex == nil && value.translation.width == 0 && value.translation.height == 0 {
                                                // Check if we're near a transient marker handle (at the top)
                                                if value.startLocation.y < 20 {
                                                    viewModel.draggingMarkerIndex = viewModel.findMarkerNearPosition(
                                                        x: value.startLocation.x,
                                                        width: geometry.size.width,
                                                        tolerance: 10
                                                    )
                                                }
                                            }
                                            
                                            if let dragIndex = viewModel.draggingMarkerIndex {
                                                // We're dragging a marker
                                                viewModel.moveMarker(at: dragIndex, toX: value.location.x, width: geometry.size.width)
                                            } else {
                                                // Normal selection drag
                                                print("Waveform drag changed @ \(value.location.x)")
                                                viewModel.updateTempSelection(
                                                    startX: value.startLocation.x,
                                                    currentX: value.location.x,
                                                    width: geometry.size.width
                                                )
                                            }
                                        }
                                        .onEnded { value in
                                            if let _ = viewModel.draggingMarkerIndex {
                                                // End marker dragging
                                                viewModel.draggingMarkerIndex = nil
                                                print("Marker drag ended")
                                            } else if abs(value.translation.width) < 5 && abs(value.translation.height) < 5 {
                                                // This was a single tap - do nothing (wait for double tap)
                                                print("Single tap ignored @ \(value.location.x)")
                                            } else {
                                                // End selection drag - commit but don't clear immediately
                                                print("Waveform drag end")
                                                viewModel.commitSelection()
                                            }
                                        }
                                )
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(height: height)
    }
}

// MARK: - Minimap for navigation
struct MinimapView: View {
    @ObservedObject var viewModel: EnhancedAudioViewModel
    @State private var isDraggingLeft = false
    @State private var isDraggingRight = false
    @State private var dragStartZoom: Double = 1.0
    @State private var dragStartOffset: Double = 0.0
    
    var body: some View {
        GeometryReader { geometry in
            // Put the visual stuff in a non-interactive overlay
            let width = geometry.size.width
            
            Color.clear // <- guaranteed full-size, hittable surface
                .overlay(
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.1))
                        
                        if let buffer = viewModel.sampleBuffer {
                            Waveform(samples: buffer)
                                .foregroundColor(.gray.opacity(0.7))
                                .allowsHitTesting(false)
                        }
                        
                        let indicatorWidth = max(20, width / CGFloat(viewModel.zoomLevel))
                        // With this
                        let indicatorOffset = CGFloat(viewModel.scrollOffset) * width
                                            + indicatorWidth / 2                 // move to the bar’s centre
                                            - width / 2                          // shift because the ZStack is centred
                        
                        // Zoom indicator with edge handles
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.blue.opacity(0.3))
                                .stroke(Color.blue, lineWidth: 1)
                                .frame(width: indicatorWidth, height: geometry.size.height)
                            
                            // Left edge handle
                            Rectangle()
                                .fill(Color.blue.opacity(0.001))  // Nearly invisible but still interactive
                                .frame(width: 20, height: geometry.size.height)  // Wider for easier grabbing
                                .contentShape(Rectangle())
                                .offset(x: -indicatorWidth/2 + 10)
                                .cursor(NSCursor.resizeLeftRight)
                                .highPriorityGesture(
                                    DragGesture(minimumDistance: 1)
                                        .onChanged { value in
                                            if !isDraggingLeft {
                                                isDraggingLeft = true
                                                dragStartZoom = viewModel.zoomLevel
                                                dragStartOffset = viewModel.scrollOffset
                                            }
                                            handleLeftEdgeDrag(value: value, width: width, indicatorWidth: indicatorWidth)
                                        }
                                        .onEnded { _ in
                                            isDraggingLeft = false
                                        }
                                )
                            
                            // Right edge handle
                            Rectangle()
                                .fill(Color.blue.opacity(0.001))  // Nearly invisible but still interactive
                                .frame(width: 20, height: geometry.size.height)  // Wider for easier grabbing
                                .contentShape(Rectangle())
                                .offset(x: indicatorWidth/2 - 10)
                                .cursor(NSCursor.resizeLeftRight)
                                .highPriorityGesture(
                                    DragGesture(minimumDistance: 1)
                                        .onChanged { value in
                                            if !isDraggingRight {
                                                isDraggingRight = true
                                                dragStartZoom = viewModel.zoomLevel
                                                dragStartOffset = viewModel.scrollOffset
                                            }
                                            handleRightEdgeDrag(value: value, width: width, indicatorWidth: indicatorWidth)
                                        }
                                        .onEnded { _ in
                                            isDraggingRight = false
                                        }
                                )
                        }
                        .frame(width: indicatorWidth, height: geometry.size.height)
                        .offset(x: indicatorOffset)
                    }
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                )
                .contentShape(Rectangle())
                .onTapGesture { location in
                    // Only handle taps outside the indicator
                    let indicatorWidth = width / CGFloat(viewModel.zoomLevel)
                    let indicatorStart = CGFloat(viewModel.scrollOffset) * width
                    let indicatorEnd = indicatorStart + indicatorWidth
                    
                    if location.x < indicatorStart || location.x > indicatorEnd {
                        // Tap is outside indicator, jump to position
                        guard viewModel.zoomLevel > 1.0 else { return }
                        
                        // Center the indicator at the tap position
                        let targetOffset = (location.x - indicatorWidth / 2) / (width - indicatorWidth)
                        let maxScrollOffset = 1.0 - (1.0 / viewModel.zoomLevel)
                        viewModel.scrollOffset = max(0, min(maxScrollOffset, Double(targetOffset)))
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { value in
                            // Only handle drag on the indicator itself, not edges
                            guard !isDraggingLeft && !isDraggingRight else { return }
                            
                            let indicatorWidth = width / CGFloat(viewModel.zoomLevel)
                            let indicatorStart = CGFloat(viewModel.scrollOffset) * width
                            let indicatorEnd = indicatorStart + indicatorWidth
                            
                            // Check if drag started within the indicator (but not on edges)
                            let startX = value.startLocation.x
                            let edgeThreshold: CGFloat = 15
                            
                            if startX >= indicatorStart + edgeThreshold && 
                               startX <= indicatorEnd - edgeThreshold {
                                // Drag the indicator
                                guard viewModel.zoomLevel > 1.0 else { return }
                                
                                let dragDelta = value.translation.width / width
                                let newOffset = viewModel.scrollOffset + Double(dragDelta) / viewModel.zoomLevel
                                let maxScrollOffset = 1.0 - (1.0 / viewModel.zoomLevel)
                                viewModel.scrollOffset = max(0, min(maxScrollOffset, newOffset))
                            }
                        }
                )
        }
        .frame(height: 60)
    }
    
    private func handleLeftEdgeDrag(value: DragGesture.Value, width: CGFloat, indicatorWidth: CGFloat) {
        let delta = value.translation.width / width
        let newIndicatorWidth = max(20, indicatorWidth - value.translation.width)
        let newZoom = width / newIndicatorWidth
        
        if newZoom >= 1.0 && newZoom <= 500.0 {
            viewModel.zoomLevel = newZoom
            // Adjust scroll to keep right edge fixed
            let rightEdge = dragStartOffset + 1.0 / dragStartZoom
            viewModel.scrollOffset = max(0, min(1 - 1/newZoom, rightEdge - 1.0 / newZoom))
        }
    }
    
    private func handleRightEdgeDrag(value: DragGesture.Value, width: CGFloat, indicatorWidth: CGFloat) {
        let newIndicatorWidth = max(20, indicatorWidth + value.translation.width)
        let newZoom = width / newIndicatorWidth
        
        if newZoom >= 1.0 && newZoom <= 500.0 {
            viewModel.zoomLevel = newZoom
            // Keep left edge fixed
            viewModel.scrollOffset = max(0, min(1 - 1/newZoom, dragStartOffset))
        }
    }
}

// MARK: - Cursor Extension
extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { hovering in
            if hovering {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
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
                
                Button(action: {
                    print(">>> TRANSIENT BUTTON TAPPED <<<")
                    print("SampleBuffer is nil: \(viewModel.sampleBuffer == nil)")
                    print("Total samples: \(viewModel.totalSamples)")
                    viewModel.detectTransients()
                }) {
                    Text("Detect Transients")
                }
                .buttonStyle(OrangeButtonStyle())
                .disabled(viewModel.sampleBuffer == nil)
                
                Button(action: { viewModel.showImporter = true }) {
                    Label("Import WAV", systemImage: "waveform")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            .onAppear {
                print("View appeared - SampleBuffer is nil: \(viewModel.sampleBuffer == nil)")
            }
            
            // Minimap for navigation
            VStack(alignment: .leading, spacing: 4) {
                Text("Overview")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                
                // TEMPORARY: Re-enable minimap to test if it's the culprit
                MinimapView(viewModel: viewModel)
                    .padding(.horizontal)
                /*
                Rectangle()
                    .fill(Color.red.opacity(0.3))
                    .frame(height: 60)
                    .overlay(Text("MINIMAP DISABLED FOR TESTING"))
                    .padding(.horizontal)
                */
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
                
                // TEMPORARY: Comment out waveform to test button interference
                EnhancedWaveformView(viewModel: viewModel)
                    .padding(.horizontal)
                    .clipped() // Ensure it doesn't extend beyond its bounds
                /*
                Rectangle()
                    .fill(Color.blue.opacity(0.3))
                    .frame(height: 400)
                    .overlay(Text("WAVEFORM DISABLED FOR TESTING"))
                    .padding(.horizontal)
                */
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
