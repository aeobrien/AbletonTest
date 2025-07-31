import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import AppKit
import Accelerate

// Compute the end sample of the region starting at `marker`
private func endOfRegion(after marker: Marker, markers: [Marker], totalSamples: Int) -> Int {
    if let custom = marker.customEndPosition { return custom }
    let sorted = markers.sorted { $0.samplePosition < $1.samplePosition }
    if let idx = sorted.firstIndex(where: { $0.id == marker.id }), idx < sorted.count - 1 {
        return sorted[idx + 1].samplePosition
    }
    return totalSamples
}

// MARK: - Transient Detection Algorithm
enum TransientDetectionAlgorithm: String, CaseIterable {
    case energy = "Energy"
    case superFlux = "SuperFlux++"
    case IRCAM = "IRCAM-style"
    case multiscaleTimeDomain = "Multiscale Time-Domain"

    
    var displayName: String { self.rawValue }
}

// MARK: - Outlier Detection
struct OutlierInfo {
    let outlierMarkerIDs: [UUID]  // Store marker IDs instead of indices
    let normalRange: ClosedRange<Int>
    let suggestedTrimLength: Int
}

// MARK: - Enhanced View Model with AudioKit Waveform support
@MainActor
final class EnhancedAudioViewModel: ObservableObject {
    // Audio data
    @Published var sampleBuffer: SampleBuffer?
    @Published var totalSamples: Int = 0
    
    @Published var sampleRate: Double = 44100.0
    
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
    @Published var autoAssignGroups = false  // Changed to false by default
    @Published var showGroupAssignmentMenu = false
    @Published var pendingGroupAssignment: ClosedRange<Int>? = nil
    
    // Transient detection
    @Published var transientThreshold: Double = 1.5
    @Published var transientOffsetMs: Double = 0.0  // Milliseconds to pre-empt transients
    @Published var transientMarkers: Set<Int> = []
    @Published var hasDetectedTransients = false
    @Published var showTransientMarkers = true
    @Published var selectedDetectionAlgorithm: TransientDetectionAlgorithm = .multiscaleTimeDomain
    @Published var isDetectingTransients = false
    
    // Transient inspection mode
    @Published var isInspectingTransients = false
    @Published var currentTransientIndex = 0
    @Published var autoAdvance = false
    @Published var autoAudition = false
    @Published var auditionLoopDuration: Double = 1.0 // Duration in seconds
    
    // Outlier detection
    @Published var showOutlierAlert = false
    var pendingOutlierInfo: (groupNumber: Int, markersToAssign: [(index: Int, marker: Marker)], outlierInfo: OutlierInfo)?
    
    // Computed properties for visible range
    var visibleStart: Int {
        let start = Int(scrollOffset * Double(totalSamples))
        return min(max(0, start), totalSamples - 1)
    }
    
    var visibleLength: Int {
        let length = Int(Double(totalSamples) / zoomLevel)
        return min(length, totalSamples - visibleStart)
    }
    
    // Group the markers by their group ID
    var markerGroups: [TransientGroup] {
        let groupedMarkers = Dictionary(grouping: markers.filter { $0.group != nil }, by: { $0.group! })
        return groupedMarkers.map { TransientGroup(id: $0.key, markers: $0.value) }
            .sorted { $0.id < $1.id }
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
            self.sampleRate = file.fileFormat.sampleRate
            
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
        print("Adding marker at x=\(x), width=\(width), sample=\(sample)")
        let newMarker = Marker(samplePosition: sample)
        markers.append(newMarker)
        // Add to transientMarkers if it's not assigned to a group
        if newMarker.group == nil {
            transientMarkers.insert(sample)
        }
        print("Total markers now: \(markers.count)")
        
        // Check if this new marker affects the endpoint of the previous marker
        let sortedMarkers = markers.sorted { $0.samplePosition < $1.samplePosition }
        if let newIndex = sortedMarkers.firstIndex(where: { $0.id == newMarker.id }),
           newIndex > 0 {
            let previousMarker = sortedMarkers[newIndex - 1]
            if let prevIndex = markers.firstIndex(where: { $0.id == previousMarker.id }) {
                // Update the previous marker's endpoint (programmatically, not user action)
                updateRegionEndpoint(markerIndex: prevIndex, newEndPosition: sample, isUserAction: false)
            }
        }
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
    
    func moveMarkerEndPosition(at index: Int, toX x: CGFloat, width: CGFloat) {
        guard index >= 0 && index < markers.count else { return }
        let newEndPosition = sampleIndex(for: x, in: width)
        let oldEndPosition = markers[index].customEndPosition
        updateRegionEndpoint(markerIndex: index, newEndPosition: newEndPosition, isUserAction: true)
        print("moveMarkerEndPosition - X: \(x), Width: \(width), Old end: \(String(describing: oldEndPosition)), New end: \(newEndPosition)")
        print("Visible range: \(visibleStart) to \(visibleStart + visibleLength), Zoom: \(zoomLevel)")
    }
    
    func resetMarkerEndPosition(at index: Int) {
        guard index >= 0 && index < markers.count else { return }
        markers[index].customEndPosition = nil
    }
    
    // MARK: Amplitude detection for region endpoint adjustment
    private func adjustRegionEndpointIfNeeded(markerIndex: Int, newEndPosition: Int) {
        guard let buffer = sampleBuffer,
              markerIndex >= 0 && markerIndex < markers.count else { return }
        
        let marker = markers[markerIndex]
        let startPosition = marker.samplePosition
        
        // Don't adjust if the region is too small
        let regionLength = newEndPosition - startPosition
        guard regionLength > 4410 else { return } // At least 100ms at 44.1kHz
        
        // Analyze the last 50ms of the region
        let analysisWindowMs = 50.0
        let sampleRate = self.sampleRate
        let analysisWindowSamples = Int(analysisWindowMs * sampleRate / 1000.0)
        
        let analysisStart = max(startPosition, newEndPosition - analysisWindowSamples)
        let analysisEnd = min(newEndPosition, buffer.samples.count)
        
        guard analysisEnd > analysisStart else { return }
        
        // Calculate RMS in small windows to detect amplitude increase
        let windowSize = 441 // 10ms windows
        let numWindows = (analysisEnd - analysisStart) / windowSize
        
        guard numWindows >= 2 else { return }
        
        var windowRMS: [Float] = []
        
        for i in 0..<numWindows {
            let windowStart = analysisStart + i * windowSize
            let windowEnd = min(windowStart + windowSize, analysisEnd)
            
            var sum: Float = 0
            for j in windowStart..<windowEnd {
                let sample = buffer.samples[j]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(windowEnd - windowStart))
            windowRMS.append(rms)
        }
        
        // Check if amplitude is increasing significantly at the end
        guard windowRMS.count >= 2 else { return }
        
        let lastRMS = windowRMS.last!
        let avgRMS = windowRMS.dropLast().reduce(0, +) / Float(windowRMS.count - 1)
        
        // If the last window is significantly louder than the average, we might be catching the next transient
        let threshold: Float = 2.0 // Last window is 2x louder than average
        
        if lastRMS > avgRMS * threshold {
            // Find where the amplitude started increasing
            var cutoffIndex = windowRMS.count - 1
            
            // Walk backwards to find where amplitude started rising
            for i in (1..<windowRMS.count).reversed() {
                if windowRMS[i] <= avgRMS * 1.2 { // 20% above average
                    cutoffIndex = i
                    break
                }
            }
            
            // Adjust the endpoint
            let samplesToTrim = (windowRMS.count - cutoffIndex) * windowSize
            let adjustedEndPosition = newEndPosition - samplesToTrim
            
            // Ensure we don't trim too much
            if adjustedEndPosition > startPosition + 2205 { // Keep at least 50ms
                markers[markerIndex].customEndPosition = adjustedEndPosition
                print("Adjusted region endpoint from \(newEndPosition) to \(adjustedEndPosition) (trimmed \(samplesToTrim) samples)")
            }
        }
    }
    
    // This should be called whenever a region's endpoint is updated programmatically
    func updateRegionEndpoint(markerIndex: Int, newEndPosition: Int, isUserAction: Bool = false) {
        guard markerIndex >= 0 && markerIndex < markers.count else { 
            print("DEBUG: updateRegionEndpoint - Invalid marker index \(markerIndex)")
            return 
        }
        
        let oldEndPosition = markers[markerIndex].customEndPosition
        print("DEBUG: updateRegionEndpoint - Marker \(markerIndex) at position \(markers[markerIndex].samplePosition)")
        print("DEBUG: updateRegionEndpoint - Old end: \(String(describing: oldEndPosition)), New end: \(newEndPosition)")
        
        if isUserAction {
            // User explicitly set this endpoint, respect their choice
            markers[markerIndex].customEndPosition = newEndPosition
        } else {
            // Programmatic update, check if adjustment is needed
            markers[markerIndex].customEndPosition = newEndPosition
            adjustRegionEndpointIfNeeded(markerIndex: markerIndex, newEndPosition: newEndPosition)
        }
        
        print("DEBUG: updateRegionEndpoint - Final end position: \(String(describing: markers[markerIndex].customEndPosition))")
    }
    
    func deleteMarker(at index: Int) {
        guard index >= 0 && index < markers.count else { return }
        let marker = markers[index]
        
        // If we're in inspection mode and deleting the current transient, move to next
        if isInspectingTransients && marker.group == nil {
            let sortedTransients = Array(transientMarkers).sorted()
            if let currentIndex = sortedTransients.firstIndex(of: marker.samplePosition) {
                if currentIndex == currentTransientIndex {
                    // Remove from transientMarkers first
                    transientMarkers.remove(marker.samplePosition)
                    markers.remove(at: index)
                    
                    // If there are still transients, focus on the next one
                    if !transientMarkers.isEmpty {
                        let newSortedTransients = Array(transientMarkers).sorted()
                        // Adjust index if needed
                        if currentTransientIndex >= newSortedTransients.count {
                            currentTransientIndex = newSortedTransients.count - 1
                        }
                        focusOnTransient(at: currentTransientIndex)
                    } else {
                        // No more transients, exit inspection mode
                        stopTransientInspection()
                    }
                    return
                }
            }
        }
        
        // Remove from transientMarkers if it's a transient
        if marker.group == nil {
            transientMarkers.remove(marker.samplePosition)
        }
        
        markers.remove(at: index)
    }
    
    func moveMarker(at index: Int, toX x: CGFloat, width: CGFloat) {
        guard index >= 0 && index < markers.count else { return }
        let oldSamplePosition = markers[index].samplePosition
        let newSamplePosition = sampleIndex(for: x, in: width)
        
        print("moveMarker - index: \(index), x: \(x), oldPos: \(oldSamplePosition), newPos: \(newSamplePosition)")
        
        // Update transientMarkers set if this is a transient marker
        if markers[index].group == nil {
            transientMarkers.remove(oldSamplePosition)
            transientMarkers.insert(newSamplePosition)
        }
        
        markers[index].samplePosition = newSamplePosition
    }
    
    @Published var isDraggingTransientInInspectMode = false
    @Published var preInspectDragZoom: Double = 1.0
    @Published var preInspectDragOffset: Double = 0.0
    
    private var auditionTimer: Timer?
    
    func startTransientDragInInspectMode(marker: Marker) {
        guard isInspectingTransients else { return }
        print("=== START TRANSIENT DRAG IN INSPECT MODE ===")
        print("Marker position before drag: \(marker.samplePosition)")
        
        isDraggingTransientInInspectMode = true
        preInspectDragZoom = zoomLevel
        preInspectDragOffset = scrollOffset
        
        // Zoom to show 100ms (50ms each side) around the marker
        let sampleRate = self.sampleRate
        let samplesFor50ms = Int(50.0 * sampleRate / 1000.0)
        let startSample = max(0, marker.samplePosition - samplesFor50ms)
        let endSample = min(totalSamples, marker.samplePosition + samplesFor50ms)
        let regionSize = endSample - startSample
        
        // Calculate zoom to show this region
        let targetZoom = Double(totalSamples) / Double(regionSize)
        zoomLevel = min(targetZoom, 500.0) // Cap at max zoom
        print("Zoom changed from \(preInspectDragZoom) to \(zoomLevel)")
        
        // Center on the marker
        let markerPosition = Double(marker.samplePosition) / Double(totalSamples)
        scrollOffset = max(0, min(1.0 - 1.0/zoomLevel, markerPosition - 0.5/zoomLevel))
        
        // Start audition if enabled
        if autoAudition {
            startAuditionLoop(marker: marker)
        }
    }
    
    @Published var currentDraggedMarkerIndex: Int? = nil
    
    private func startAuditionLoop(marker: Marker) {
        guard let player = audioPlayer, let buffer = sampleBuffer else { return }
        
        // Stop any existing audition
        stopAuditionLoop()
        
        // Store the marker index for real-time position updates
        currentDraggedMarkerIndex = markers.firstIndex(where: { $0.id == marker.id })
        
        // Function to play the loop
        func playLoop() {
            // Get the current position of the marker being dragged
            guard let markerIndex = currentDraggedMarkerIndex,
                  markerIndex < markers.count else { return }
            
            let currentMarker = markers[markerIndex]
            let sampleRate = player.format.sampleRate
            let startTime = TimeInterval(currentMarker.samplePosition) / sampleRate
            
            // Calculate duration based on loop setting
            let loopDurationSamples = Int(auditionLoopDuration * sampleRate)
            
            // Find end position (either custom, next marker, or loop duration later)
            let endPosition: Int
            
            if let customEnd = currentMarker.customEndPosition {
                endPosition = min(customEnd, currentMarker.samplePosition + loopDurationSamples)
            } else {
                let allMarkerPositions = markers.map { $0.samplePosition }.sorted()
                if let nextIndex = allMarkerPositions.firstIndex(where: { $0 > currentMarker.samplePosition }) {
                    endPosition = min(allMarkerPositions[nextIndex], currentMarker.samplePosition + loopDurationSamples)
                } else {
                    endPosition = min(buffer.samples.count, currentMarker.samplePosition + loopDurationSamples)
                }
            }
            
            let endTime = TimeInterval(endPosition) / sampleRate
            let duration = endTime - startTime
            
            // Play from the current marker position
            player.stop()
            player.currentTime = startTime
            player.play()
            
            // Schedule stop and restart
            auditionTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
                if self.isDraggingTransientInInspectMode && self.autoAudition {
                    playLoop() // Restart the loop with updated position
                }
            }
        }
        
        // Start the first loop
        playLoop()
    }
    
    private func stopAuditionLoop() {
        auditionTimer?.invalidate()
        auditionTimer = nil
        currentDraggedMarkerIndex = nil
        if audioPlayer?.isPlaying == true {
            audioPlayer?.stop()
        }
    }
    
    func endTransientDragInInspectMode() {
        guard isDraggingTransientInInspectMode else { return }
        print("=== END TRANSIENT DRAG IN INSPECT MODE ===")
        
        // Stop audition if it was playing
        if autoAudition {
            stopAuditionLoop()
        }
        
        // Log marker positions before returning to normal view
        let sortedTransients = Array(transientMarkers).sorted()
        if currentTransientIndex < sortedTransients.count {
            let currentPosition = sortedTransients[currentTransientIndex]
            if let markerIndex = markers.firstIndex(where: { $0.samplePosition == currentPosition }) {
                print("Marker position after drag: \(markers[markerIndex].samplePosition)")
            }
        }
        
        isDraggingTransientInInspectMode = false
        
        // If Auto Advance is enabled, move to the next transient
        if autoAdvance && currentTransientIndex < markers.count - 1 {
            nextTransient()
        } else {
            // Return to inspect mode zoom for the current region
            focusOnTransient(at: currentTransientIndex)
        }
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
            
            // Get the markers being assigned
            let markersToAssign = markers.enumerated()
                .filter { range.contains($0.element.samplePosition) }
                .map { (index: $0.offset, marker: $0.element) }
            
            // Get existing markers in this group (which will be empty for a new group)
            let existingGroupMarkers = markers.filter { $0.group == newGroup }
            
            // Combine for outlier detection
            let allMarkersInGroup = markersToAssign.map { $0.marker } + existingGroupMarkers
            
            // Check for outliers
            if let outlierInfo = detectRegionLengthOutliers(markers: allMarkersInGroup) {
                // Store the info for the alert
                pendingOutlierInfo = (
                    groupNumber: newGroup,
                    markersToAssign: markersToAssign,
                    outlierInfo: outlierInfo
                )
                showOutlierAlert = true
            } else {
                // No outliers, proceed with assignment
                for (index, _) in markersToAssign {
                    markers[index].group = newGroup
                }
            }
            // Keep selection visible for playback
            // tempSelection = nil  // Don't clear selection
        } else {
            // Store selection for manual assignment - the UI will show the controls
            pendingGroupAssignment = range
            // Don't show popover anymore
            showGroupAssignmentMenu = false
        }
    }
    
    func clearSelection() {
        tempSelection = nil
        pendingGroupAssignment = nil
    }
    
    func zoomToSelection() {
        guard let selection = tempSelection ?? pendingGroupAssignment,
              totalSamples > 0 else { return }
        
        // Calculate the zoom level needed to fill the view with the selection
        let selectionLength = selection.upperBound - selection.lowerBound
        let desiredZoomLevel = Double(totalSamples) / Double(selectionLength)
        
        // Apply reasonable limits
        zoomLevel = max(1.0, min(500.0, desiredZoomLevel * 0.9)) // 0.9 to add some padding
        
        // Center the view on the selection
        let selectionCenter = Double(selection.lowerBound + selection.upperBound) / 2.0
        let centerOffset = selectionCenter / Double(totalSamples)
        
        // Calculate offset to center the selection
        scrollOffset = max(0, min(1.0 - 1.0/zoomLevel, centerOffset - 0.5/zoomLevel))
    }
    
    func assignToGroup(_ groupNumber: Int) {
        guard let range = pendingGroupAssignment else { return }
        
        // Get the markers being assigned
        let markersToAssign = markers.enumerated()
            .filter { range.contains($0.element.samplePosition) }
            .map { (index: $0.offset, marker: $0.element) }
        
        // Get existing markers in this group
        let existingGroupMarkers = markers.filter { $0.group == groupNumber }
        
        // Combine for outlier detection
        let allMarkersInGroup = markersToAssign.map { $0.marker } + existingGroupMarkers
        
        // Check for outliers
        if let outlierInfo = detectRegionLengthOutliers(markers: allMarkersInGroup) {
            // Store the info for the alert
            pendingOutlierInfo = (
                groupNumber: groupNumber,
                markersToAssign: markersToAssign,
                outlierInfo: outlierInfo
            )
            showOutlierAlert = true
        } else {
            // No outliers, proceed with assignment
            for (index, _) in markersToAssign {
                markers[index].group = groupNumber
            }
            pendingGroupAssignment = nil
            tempSelection = nil
            showGroupAssignmentMenu = false
        }
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
    
    // MARK: Outlier Detection
    private func detectRegionLengthOutliers(markers: [Marker]) -> OutlierInfo? {
        guard markers.count >= 3 else { return nil }
        
        // Calculate region lengths
        let sortedMarkers = markers.sorted { $0.samplePosition < $1.samplePosition }
        var regionLengths: [(index: Int, length: Int)] = []
        
        for i in 0..<sortedMarkers.count {
            let endPosition = endOfRegion(after: sortedMarkers[i], 
                                        markers: self.markers, 
                                        totalSamples: totalSamples)
            let length = endPosition - sortedMarkers[i].samplePosition
            regionLengths.append((index: i, length: length))
        }
        
        // Sort by length to find outliers
        let sortedByLength = regionLengths.sorted { $0.length < $1.length }
        
        // Calculate median and IQR
        let medianIndex = sortedByLength.count / 2
        let q1Index = sortedByLength.count / 4
        let q3Index = (sortedByLength.count * 3) / 4
        
        let median = sortedByLength[medianIndex].length
        let q1 = sortedByLength[q1Index].length
        let q3 = sortedByLength[q3Index].length
        let iqr = q3 - q1
        
        // Define outlier threshold (1.5 * IQR method)
        let upperBound = q3 + Int(1.5 * Double(iqr))
        
        // Find outliers
        var outlierMarkerIDs: [UUID] = []
        var outlierIndices: [Int] = []  // Keep for internal use
        for (originalIndex, length) in regionLengths {
            if length > upperBound {
                outlierIndices.append(originalIndex)
                outlierMarkerIDs.append(sortedMarkers[originalIndex].id)
            }
        }
        
        // If we have outliers, calculate suggested trim length
        guard !outlierMarkerIDs.isEmpty else { return nil }
        
        // Find the longest non-outlier region
        let nonOutlierLengths = regionLengths
            .filter { !outlierIndices.contains($0.index) }
            .map { $0.length }
        
        guard let maxNormalLength = nonOutlierLengths.max() else { return nil }
        
        return OutlierInfo(
            outlierMarkerIDs: outlierMarkerIDs,
            normalRange: q1...q3,
            suggestedTrimLength: maxNormalLength
        )
    }
    
    func confirmOutlierTrimming() {
        guard let info = pendingOutlierInfo else { return }
        
        // Trim the outlier regions
        for (index, marker) in info.markersToAssign {
            // Check if this marker is an outlier by ID
            if info.outlierInfo.outlierMarkerIDs.contains(marker.id) {
                // Trim this region to the suggested length
                let markerPosition = marker.samplePosition
                let newEndPosition = markerPosition + info.outlierInfo.suggestedTrimLength
                
                print("DEBUG: Trimming outlier marker at position \(markerPosition) from current length to \(info.outlierInfo.suggestedTrimLength)")
                
                updateRegionEndpoint(markerIndex: index, newEndPosition: newEndPosition, isUserAction: false)
            }
            // Assign to group
            markers[index].group = info.groupNumber
        }
        
        // Clear state
        pendingOutlierInfo = nil
        showOutlierAlert = false
        pendingGroupAssignment = nil
        tempSelection = nil
        showGroupAssignmentMenu = false
    }
    
    func cancelOutlierTrimming() {
        guard let info = pendingOutlierInfo else { return }
        
        // Just assign without trimming
        for (index, _) in info.markersToAssign {
            markers[index].group = info.groupNumber
        }
        
        // Clear state
        pendingOutlierInfo = nil
        showOutlierAlert = false
        pendingGroupAssignment = nil
        tempSelection = nil
        showGroupAssignmentMenu = false
    }
    
    // MARK: Zoom and scroll helpers
    // MARK: Zoom and scroll helpers
    func zoom(by factor: Double, at location: CGFloat, in width: CGFloat) {
        // Compute the target zoom without mutating state first
        let oldZoom = zoomLevel
        let newZoom = max(1.0, min(500.0, oldZoom * factor))
        
        guard newZoom != oldZoom,
              totalSamples > 0,
              width > 0 else { return }
        
        // Normalised pointer location in [0, 1]
        let normalizedLocation = max(0, min(1, location / width))
        
        // Use the OLD visible length to find which sample is under the anchor
        let oldVisibleLength = Double(totalSamples) / oldZoom
        let sampleAtLocation = Double(visibleStart) + normalizedLocation * oldVisibleLength
        
        // Now switch to the new zoom and compute the new start so the anchor stays put
        let newVisibleLength = Double(totalSamples) / newZoom
        let newStart = sampleAtLocation - normalizedLocation * newVisibleLength
        
        // Commit state
        zoomLevel = newZoom
        scrollOffset = max(0, min(1 - 1/newZoom, newStart / Double(totalSamples)))
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
        Task { @MainActor in
            print("=== TRANSIENT DETECTION START ===")
            print("Using algorithm: \(selectedDetectionAlgorithm.displayName)")
            guard let buffer = sampleBuffer else {
                print("No sample buffer available")
                return
            }
            
            // Set detecting flag
            isDetectingTransients = true
            
            // Give UI time to update
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            
            // Clear existing markers
            transientMarkers.removeAll()
        let samples = buffer.samples
        print("Total samples: \(samples.count)")
        guard samples.count > 10 else {
            print("Not enough samples")
            isDetectingTransients = false
            return
        }
        
        // Determine the region to analyze
        let startSample: Int
        let endSample: Int
        if let selection = tempSelection, selection.upperBound > selection.lowerBound {
            // Use selected region
            startSample = selection.lowerBound
            endSample = selection.upperBound
            print("Detecting transients in selected region: \(startSample) to \(endSample)")
            print("Selection range size: \(endSample - startSample) samples")
        } else {
            // Use entire file
            startSample = 0
            endSample = samples.count
            print("Detecting transients in entire file")
        }
        
        // Debug current state
        print("Current threshold: \(transientThreshold)")
        print("Sample range to analyze: \(endSample - startSample) samples")
        
        var detectedTransients: Set<Int> = []
        
        switch selectedDetectionAlgorithm {
        case .energy:
            detectedTransients = detectTransientsUsingEnergy(samples: samples,
                                                            startSample: startSample,
                                                            endSample: endSample)

        case .superFlux:
            detectedTransients = detectTransientsUsingSuperFlux(samples: samples,
                                                                startSample: startSample,
                                                                endSample: endSample)

        case .IRCAM:
            detectedTransients = detectTransientsUsingIRCAMStyle(samples: samples,
                                                                 startSample: startSample,
                                                                 endSample: endSample)

        case .multiscaleTimeDomain:
            detectedTransients = detectTransientsUsingMultiscaleTimeDomain(samples: samples,
                                                                           startSample: startSample,
                                                                           endSample: endSample)
        }
        
        transientMarkers = detectedTransients
        hasDetectedTransients = true
        
        print("Detected \(detectedTransients.count) transients with threshold \(transientThreshold)")
        print("=== TRANSIENT DETECTION END ===")
        
        // Update markers to include transients
        updateMarkersWithTransients()
        
        // Clear detecting flag
        isDetectingTransients = false
        }
    }
    
    // MARK: Energy-based transient detection (original algorithm)
    private func detectTransientsUsingEnergy(samples: [Float], startSample: Int, endSample: Int) -> Set<Int> {
        // Use larger window for better transient detection
        let windowSize = 2048
        let hopSize = windowSize / 2
        let regionLength = endSample - startSample
        let windowCount = max(0, (regionLength - windowSize) / hopSize + 1)
        
        var energyValues: [Float] = []
        
        // Calculate energy for each window
        for i in 0..<windowCount {
            let windowStart = startSample + i * hopSize
            let windowEnd = min(windowStart + windowSize, endSample)
            
            if windowEnd > windowStart {
                let window = Array(samples[windowStart..<windowEnd])
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
            let detectionThreshold = mean + Float(transientThreshold * 2) * stdDev
            
            print("Energy stats - Mean: \(mean), StdDev: \(stdDev), Threshold: \(detectionThreshold)")
            
            var lastTransientSample = -minSpacing
            
            for i in 1..<(energyValues.count - 1) {
                let prev = energyValues[i - 1]
                let curr = energyValues[i]
                let next = energyValues[i + 1]
                
                // Check if this is a local peak above threshold
                if curr > prev && curr > next && curr > detectionThreshold {
                    let samplePosition = startSample + i * hopSize  // region offset
                    let sr = sampleRate                              // ← use the model’s real sample rate
                    let minSpacingSamples = Int(0.25 * sr)           // keep your 0.25s policy; feel free to tune

                    if samplePosition - lastTransientSample >= minSpacingSamples {
                        // 2nd-stage micro-alignment (exact attack + zero-cross)
                        let refined = refineOnset(
                            samples: samples,
                            roughIndex: samplePosition,
                            sampleRate: sr,
                            searchBackMs: 25,      // widen if you tend to land late
                            searchForwardMs: 10,   // widen if you tend to land early
                            energyWinMs: 1.5,
                            holdMs: 1.0,
                            kSigma: Float(max(1.5, min(4.0, transientThreshold * 3.0))),
                            zcSearchMs: 4.0
                        )

                        let offsetSamples = Int(transientOffsetMs * sr / 1000.0)
                        let finalPos = max(0, refined + offsetSamples)

                        detectedTransients.insert(finalPos)
                        lastTransientSample = samplePosition
                    }
                }
            }
        }
        
        return detectedTransients
    }
    
    // MARK: SuperFlux++ (log-magnitude spectral flux with time max-filter, zero-phase smoothing)
    private func detectTransientsUsingSuperFlux(samples: [Float],
                                                startSample: Int,
                                                endSample: Int) -> Set<Int> {
        // ---- Parameters (tweak if needed) ----
        let sampleRate: Double = 44100.0
        let winSize = 2048                 // ~46 ms at 44.1k
        let hopSize = 256                  // ~5.8 ms hop
        let maxFilterLookback = 3          // frames for vibrato suppression
        let smoothRadius = 3               // frames (zero-phase)
        let minSpacingMs = 30.0            // minimum distance between onsets
        let kStd = Float(max(0.1, min(3.0, transientThreshold * 3.0))) // adaptive scale from UI slider
        
        // ---- 1) STFT magnitude spectrogram (log1p compression) ----
        let region = Array(samples[startSample..<endSample])
        let frames = max(0, (region.count - winSize) / hopSize + 1)
        if frames < 3 { return [] }

        let hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                               count: winSize, isHalfWindow: false)

        // FFT setup
        let log2n = vDSP_Length(round(log2(Float(winSize))))
        guard let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fft) }

        var mags: [[Float]] = Array(repeating: Array(repeating: 0, count: winSize/2), count: frames)

        // Reusable buffers
        var real = [Float](repeating: 0, count: winSize/2)
        var imag = [Float](repeating: 0, count: winSize/2)
        var frameBuf = [Float](repeating: 0, count: winSize)

        for t in 0..<frames {
            let s = t * hopSize
            // windowed frame
            vDSP.multiply(region[s..<(s+winSize)], hann, result: &frameBuf)

            // Pack real input into split-complex
            var split = DSPSplitComplex(realp: &real, imagp: &imag)
            frameBuf.withUnsafeBytes { raw in
                let ptr = raw.bindMemory(to: DSPComplex.self)
                vDSP_ctoz(ptr.baseAddress!, 2, &split, 1, vDSP_Length(winSize/2))
            }

            // FFT
            vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))

            // Convert to magnitudes
            var mag2 = [Float](repeating: 0, count: winSize/2)
            vDSP_zvmags(&split, 1, &mag2, 1, vDSP_Length(winSize/2))

            // sqrt for magnitude (vForce)
            var mag = [Float](repeating: 0, count: winSize/2)
            var n = Int32(mag.count)
            vvsqrtf(&mag, mag2, &n)

            // log compression
            var one: Float = 1.0
            vDSP_vsadd(mag, 1, &one, &mag, 1, vDSP_Length(mag.count)) // mag = mag + 1
            var nLog = Int32(mag.count)
            vvlogf(&mag, mag, &nLog)                                   // mag = log(mag)

            mags[t] = mag
        }

        // ---- 2) SuperFlux novelty: time max-filter + half-wave rectified first difference ----
        var novelty = [Float](repeating: 0, count: frames)
        if frames >= 2 {
            for t in 1..<frames {
                var sumPos: Float = 0
                // For each bin, compare to maximum over the past few frames
                let t0 = max(0, t - maxFilterLookback)
                for k in 0..<winSize/2 {
                    var prevMax: Float = mags[t0][k]
                    if t0 < t {
                        for u in (t0..<t) {
                            if mags[u][k] > prevMax { prevMax = mags[u][k] }
                        }
                    }
                    let d = mags[t][k] - prevMax
                    if d > 0 { sumPos += d }
                }
                novelty[t] = sumPos
            }
        }

        // ---- 3) Zero-phase smoothing & local baseline subtraction ----
        novelty = zeroPhaseSmooth(novelty, radius: smoothRadius)
        let baseline = movingAverage(novelty, radius: 10) // ~10 * 5.8ms ≈ 58ms
        var nf = [Float](repeating: 0, count: frames)
        vDSP_vsub(baseline, 1, novelty, 1, &nf, 1, vDSP_Length(frames)) // nf = novelty - baseline
        // rectify
        for i in 0..<nf.count { if nf[i] < 0 { nf[i] = 0 } }

        // ---- 4) Global threshold + peak picking ----
        let (mu, sigma) = meanStd(nf)
        let thr = mu + kStd * sigma
        let minSpacingSamples = Int((minSpacingMs / 1000.0) * sampleRate)
        let onsetFrames = peakPick(nf, threshold: thr, minSeparation: 2) // ≥ ~12 ms

        let sr = sampleRate
        let offsetSamples = Int(transientOffsetMs * sr / 1000.0)
        var lastPlaced = -minSpacingSamples
        var out: Set<Int> = []

        for f in onsetFrames {
            let rough = startSample + f * hopSize

            let refined = refineOnset(
                samples: samples,
                roughIndex: rough,
                sampleRate: sr,
                searchBackMs: 25,
                searchForwardMs: 10,
                energyWinMs: 1.5,
                holdMs: 1.0,
                kSigma: Float(max(1.5, min(4.0, transientThreshold * 3.0))),
                zcSearchMs: 4.0
            )

            let finalPos = max(0, refined + offsetSamples)
            if finalPos - lastPlaced >= minSpacingSamples {
                out.insert(finalPos)
                lastPlaced = finalPos
            }
        }
        return out
    }

    // MARK: IRCAM-style (centroid + peak-count + HF ratio with bidirectional smoothing)
    private func detectTransientsUsingIRCAMStyle(samples: [Float],
                                                 startSample: Int,
                                                 endSample: Int) -> Set<Int> {
        // ---- Parameters ----
        let sampleRate: Double = 44100.0
        let winSize = 2048
        let hopSize = 256
        let smoothRadius = 3
        let minSpacingMs = 30.0
        let kStd = Float(max(0.1, min(3.0, transientThreshold * 3.0)))

        // STFT magnitudes (shared helper)
        let spect = stftMagnitudes(samples: samples, start: startSample, end: endSample,
                                   winSize: winSize, hopSize: hopSize)
        let frames = spect.count
        if frames < 3 { return [] }
        let bins = winSize / 2
        let nyquist: Float = Float(sampleRate / 2)

        // ---- 1) Frame-wise features ----
        var centroid = [Float](repeating: 0, count: frames)
        var peakCount = [Float](repeating: 0, count: frames)
        var hfRatio = [Float](repeating: 0, count: frames)

        // Bin frequencies
        var freqs = [Float](repeating: 0, count: bins)
        for k in 0..<bins { freqs[k] = Float(k) * nyquist / Float(bins) }

        for t in 0..<frames {
            let mag = spect[t]
            var sumMag: Float = 0
            var sumFMag: Float = 0

            // centroid + HF ratio
            var hfSum: Float = 0
            let hfCut: Float = 2000 // 2 kHz
            for k in 0..<bins {
                let m = mag[k]
                sumMag += m
                sumFMag += freqs[k] * m
                if freqs[k] >= hfCut { hfSum += m }
            }
            centroid[t] = sumMag > 0 ? (sumFMag / sumMag) / nyquist : 0 // normalised 0..1
            hfRatio[t] = sumMag > 0 ? (hfSum / sumMag) : 0

            // local-peak count (simple)
            var pc: Int = 0
            if bins > 2 {
                for k in 1..<(bins - 1) {
                    let m = mag[k]
                    if m > mag[k-1] && m > mag[k+1] {
                        // rough magnitude threshold: > median of frame
                        // compute once lazily
                        pc += 1
                    }
                }
            }
            peakCount[t] = Float(pc)
        }

        // ---- 2) Bidirectional smoothing ----
        centroid = zeroPhaseSmooth(centroid, radius: smoothRadius)
        peakCount = zeroPhaseSmooth(peakCount, radius: smoothRadius)
        hfRatio = zeroPhaseSmooth(hfRatio, radius: smoothRadius)

        // ---- 3) Build novelty from positive deltas ----
        var novelty = [Float](repeating: 0, count: frames)
        let wC: Float = 0.5, wP: Float = 0.3, wH: Float = 0.2
        for t in 1..<frames {
            let dC = max(0, centroid[t] - centroid[t-1])
            let dP = max(0, peakCount[t] - peakCount[t-1])
            let dH = max(0, hfRatio[t] - hfRatio[t-1])
            novelty[t] = wC * dC + wP * dP + wH * dH
        }

        // Local baseline removal
        let baseline = movingAverage(novelty, radius: 10)
        var nf = [Float](repeating: 0, count: frames)
        vDSP_vsub(baseline, 1, novelty, 1, &nf, 1, vDSP_Length(frames))
        for i in 0..<nf.count { if nf[i] < 0 { nf[i] = 0 } }

        // ---- 4) Threshold + peak picking ----
        let (mu, sigma) = meanStd(nf)
        let thr = mu + kStd * sigma
        let minSpacingSamples = Int((minSpacingMs / 1000.0) * sampleRate)
        let onsetFrames = peakPick(nf, threshold: thr, minSeparation: 2)

        let sr = sampleRate
        let offsetSamples = Int(transientOffsetMs * sr / 1000.0)
        var lastPlaced = -minSpacingSamples
        var out: Set<Int> = []

        for f in onsetFrames {
            let rough = startSample + f * hopSize

            let refined = refineOnset(
                samples: samples,
                roughIndex: rough,
                sampleRate: sr,
                searchBackMs: 25,
                searchForwardMs: 10,
                energyWinMs: 1.5,
                holdMs: 1.0,
                kSigma: Float(max(1.5, min(4.0, transientThreshold * 3.0))),
                zcSearchMs: 4.0
            )

            let finalPos = max(0, refined + offsetSamples)
            if finalPos - lastPlaced >= minSpacingSamples {
                out.insert(finalPos)
                lastPlaced = finalPos
            }
        }
        return out
    }

    // MARK: Multiscale time-domain (dual-envelope via multi-scale differences)
    private func detectTransientsUsingMultiscaleTimeDomain(samples: [Float],
                                                           startSample: Int,
                                                           endSample: Int) -> Set<Int> {
        // ---- Parameters ----
        let sampleRate: Double = 44100.0
        let region = Array(samples[startSample..<endSample])
        let N = region.count
        if N < 2000 { return [] }

        // Scales in milliseconds (converted to samples)
        let scalesMs: [Double] = [1.0, 2.0, 4.0, 8.0]   // 1–8 ms
        let ds = scalesMs.map { max(1, Int(($0 / 1000.0) * sampleRate)) }

        // Novelty (per sample), then we’ll peak-pick with a refractory in samples
        var novelty = [Float](repeating: 0, count: N)

        for d in ds {
            if d >= N { continue }

            // 1) Multi-scale absolute difference: |x[n] - x[n-d]|
            var adiff = [Float](repeating: 0, count: N)
            for n in d..<N {
                adiff[n] = abs(region[n] - region[n - d])
            }

            // 2) Dual envelopes: fast vs slow moving averages
            let fastRadius = max(1, d / 2)
            let slowRadius = max(fastRadius + 1, d * 4)

            let fast = movingAverage(adiff, radius: fastRadius)
            let slow = movingAverage(adiff, radius: slowRadius)

            // 3) Band novelty = max(0, fast - slow)
            for n in 0..<N {
                let v = fast[n] - slow[n]
                if v > 0 { novelty[n] += v }
            }
        }

        // Zero-phase smoothing
        novelty = zeroPhaseSmooth(novelty, radius: 16) // ~16 samples ≈ 0.36 ms

        // Threshold from stats
        let (mu, sigma) = meanStd(novelty)
        let kStd = Float(max(0.1, min(5.0, transientThreshold * 5.0)))
        let thr = mu + kStd * sigma

        // Peak pick directly in sample domain
        let minSpacingSamples = Int((25.0 / 1000.0) * sampleRate)
        var peaks: [Int] = []
        var last = -minSpacingSamples
        for n in 1..<(N-1) {
            let y0 = novelty[n - 1], y1 = novelty[n], y2 = novelty[n + 1]
            if y1 > thr && y1 > y0 && y1 > y2 {
                if (n - last) >= minSpacingSamples {
                    peaks.append(n)
                    last = n
                }
            }
        }

        let sr = sampleRate
        let offsetSamples = Int(transientOffsetMs * sr / 1000.0)
        var out: Set<Int> = []
        var lastPlaced = -minSpacingSamples

        for p in peaks {
            let rough = startSample + p

            let refined = refineOnset(
                samples: samples,
                roughIndex: rough,
                sampleRate: sr,
                searchBackMs: 25,
                searchForwardMs: 10,
                energyWinMs: 1.5,
                holdMs: 1.0,
                kSigma: Float(max(1.5, min(4.0, transientThreshold * 3.0))),
                zcSearchMs: 4.0
            )

            let finalPos = max(0, refined + offsetSamples)
            if finalPos - lastPlaced >= minSpacingSamples {
                out.insert(finalPos)
                lastPlaced = finalPos
            }
        }
        return out
    }
    
    // MARK: - Micro-aligner: refine rough onsets to exact start + zero-crossing
    // 1) Look ±window around rough index
    // 2) Build short-time energy (STE) envelope
    // 3) Find earliest time STE rises above (baseline + k·sigma) and holds for a few samples
    // 4) Snap to a nearby rising zero-crossing so the cut is click-free
    private func refineOnset(samples: [Float],
                             roughIndex: Int,
                             sampleRate: Double = 44100.0,
                             searchBackMs: Double = 25.0,
                             searchForwardMs: Double = 10.0,
                             energyWinMs: Double = 1.5,     // STE window ~1.5 ms
                             holdMs: Double = 1.0,          // must stay above thr for this long
                             kSigma: Float = 3.0,           // threshold = baseline + k*std
                             zcSearchMs: Double = 4.0       // search radius for zero-crossing
    ) -> Int {
        if samples.isEmpty { return max(0, roughIndex) }

        let back = max(1, Int((searchBackMs / 1000.0) * sampleRate))
        let fwd  = max(1, Int((searchForwardMs / 1000.0) * sampleRate))
        let a = max(0, roughIndex - back)
        let b = min(samples.count, roughIndex + fwd)
        if b - a < 16 { return max(0, roughIndex) }

        // Work on a local slice for robustness & speed
        let x = Array(samples[a..<b])

        // --- Short-time energy envelope (squared -> centered moving average) ---
        let energyWin = max(4, Int((energyWinMs / 1000.0) * sampleRate)) // e.g. ~66 samples @44.1k
        let ste = shortTimeEnergy(x, win: energyWin)                      // same length as x

        // --- Local noise baseline from earliest part of the slice (first 8–12 ms or up to 30% of slice) ---
        let baselineSpan = min( max(energyWin * 4, Int(0.12 * Double(x.count))), max(energyWin * 2, x.count / 3) )
        let (mu0, sd0) = meanStd(Array(ste.prefix(baselineSpan)))
        let thr = mu0 + kSigma * sd0

        // --- Earliest sustained exceedance over threshold (with hold) ---
        let hold = max(2, Int((holdMs / 1000.0) * sampleRate))
        var idxInSlice: Int? = nil
        var run = 0
        for i in 1..<ste.count {
            if ste[i] > thr && ste[i] >= ste[i-1] {
                run += 1
                if run >= hold { idxInSlice = i - run + 1; break }
            } else {
                run = 0
            }
        }
        // Fallback: if nothing crosses, keep rough index
        let candidate = a + (idxInSlice ?? (roughIndex - a))

        // --- Snap to a nearby rising zero-crossing (prefer the last rising ZC before candidate) ---
        let zcRadius = max(4, Int((zcSearchMs / 1000.0) * sampleRate))
        let snapped = nearestRisingZeroCrossing(samples: samples,
                                                target: candidate,
                                                searchRadius: zcRadius,
                                                ste: ste,
                                                steOffset: a,
                                                thr: thr)

        return snapped
    }

    // Centered moving-average short-time energy (STE) with edge handling
    private func shortTimeEnergy(_ x: [Float], win: Int) -> [Float] {
        let n = x.count
        if n == 0 { return [] }
        if win <= 1 { return x.map { $0 * $0 } }

        // squared signal
        var sq = [Float](repeating: 0, count: n)
        vDSP_vsq(x, 1, &sq, 1, vDSP_Length(n)) // sq[i] = x[i]^2

        // prefix sums for fast windowed sum
        var prefix = [Float](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + sq[i] }

        let r = win / 2
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let a = max(0, i - r)
            let b = min(n - 1, i + r)
            let sum = prefix[b + 1] - prefix[a]
            out[i] = sum / Float(b - a + 1)
        }
        return out
    }

    // Find nearest *rising* zero-crossing near 'target'.
    // Preference order: last rising ZC at/behind target; otherwise nearest rising ZC ahead;
    // if none, return target unchanged.
    private func nearestRisingZeroCrossing(samples: [Float],
                                           target: Int,
                                           searchRadius: Int,
                                           ste: [Float],
                                           steOffset: Int,
                                           thr: Float) -> Int {
        let n = samples.count
        if n < 2 { return max(0, min(n - 1, target)) }

        let L = max(1, target - searchRadius)
        let R = min(n - 2, target + searchRadius)

        // Helper to test "rising" ZC and ensure energy ramps after it
        func isGoodRisingZC(at i: Int) -> Bool {
            // rising: x[i] <= 0 and x[i+1] > 0
            if !(samples[i] <= 0 && samples[i + 1] > 0) { return false }
            // Require the STE to exceed threshold within a short lookahead (to avoid pre-noise)
            let steIdx = max(0, min(ste.count - 1, i - steOffset))
            let look = min(ste.count - 1, steIdx + 200) // ~ up to ~4.5 ms @44.1k (tune if needed)
            if steIdx >= look { return false }
            var exceeds = false
            for k in steIdx...look where ste[k] > thr {
                exceeds = true; break
            }
            return exceeds
        }

        // 1) Search backwards for last good rising ZC at/behind target
        var bestBack: Int? = nil
        if target >= L {
            var i = min(target, R)
            while i > L {
                if isGoodRisingZC(at: i - 1) { bestBack = i - 1; break }
                i -= 1
            }
        }
        if let b = bestBack { return b }

        // 2) Otherwise search forward for the first good rising ZC ahead
        var i = max(target, L)
        while i < R {
            if isGoodRisingZC(at: i) { return i }
            i += 1
        }

        // 3) Fallback: return the target
        return max(0, min(n - 1, target))
    }

 

    // ============================
    // MARK: - Small DSP helpers
    // ============================

    // Simple mean/std (population)
    // Mean/std for Float arrays (population std)
    private func meanStd(_ x: [Float]) -> (Float, Float) {
        if x.isEmpty { return (0, 0) }
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(x.count))
        var m2: Float = 0
        vDSP_measqv(x, 1, &m2, vDSP_Length(x.count)) // mean of squares
        let varPop = max(0, m2 - mean * mean)
        return (mean, sqrtf(varPop))
    }


    // Zero-phase (forward+reverse) moving average
    private func zeroPhaseSmooth(_ x: [Float], radius: Int) -> [Float] {
        if radius <= 0 { return x }
        let y = movingAverage(x, radius: radius)
        let yr = Array(y.reversed())
        let zr = movingAverage(yr, radius: radius)
        return Array(zr.reversed())
    }

    // Centered moving average (radius r -> window = 2r+1), edges replicated
    private func movingAverage(_ x: [Float], radius: Int) -> [Float] {
        if radius <= 0 || x.isEmpty { return x }
        let n = x.count
        let w = 2 * radius + 1
        var y = [Float](repeating: 0, count: n)
        var acc: Float = 0

        // Prefix sum for efficiency
        var prefix = [Float](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i+1] = prefix[i] + x[i] }

        for i in 0..<n {
            let a = max(0, i - radius)
            let b = min(n - 1, i + radius)
            let sum = prefix[b+1] - prefix[a]
            y[i] = sum / Float(b - a + 1)
        }
        return y
    }

    // Simple peak picker on frame-domain novelty
    private func peakPick(_ novelty: [Float], threshold: Float, minSeparation: Int) -> [Int] {
        var peaks: [Int] = []
        var last = -minSeparation
        for i in 1..<(novelty.count - 1) {
            if novelty[i] > threshold && novelty[i] > novelty[i-1] && novelty[i] > novelty[i+1] {
                if (i - last) >= minSeparation {
                    peaks.append(i)
                    last = i
                }
            }
        }
        return peaks
    }

    // Small STFT helper returning log-magnitudes (frames x bins)
    private func stftMagnitudes(samples: [Float],
                                start: Int,
                                end: Int,
                                winSize: Int,
                                hopSize: Int) -> [[Float]] {
        let region = Array(samples[start..<end])
        let frames = max(0, (region.count - winSize) / hopSize + 1)
        if frames == 0 { return [] }

        let hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                               count: winSize, isHalfWindow: false)

        let log2n = vDSP_Length(round(log2(Float(winSize))))
        guard let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fft) }

        var out = Array(repeating: Array(repeating: 0 as Float, count: winSize/2), count: frames)
        var real = [Float](repeating: 0, count: winSize/2)
        var imag = [Float](repeating: 0, count: winSize/2)
        var frameBuf = [Float](repeating: 0, count: winSize)

        for t in 0..<frames {
            let s = t * hopSize
            vDSP.multiply(region[s..<(s+winSize)], hann, result: &frameBuf)

            var split = DSPSplitComplex(realp: &real, imagp: &imag)
            frameBuf.withUnsafeBytes { raw in
                let ptr = raw.bindMemory(to: DSPComplex.self)
                vDSP_ctoz(ptr.baseAddress!, 2, &split, 1, vDSP_Length(winSize/2))
            }
            vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))

            // Convert to magnitudes (squared magnitude)
            var mag2 = [Float](repeating: 0, count: winSize/2)
            vDSP_zvmags(&split, 1, &mag2, 1, vDSP_Length(winSize/2))

            // sqrt for magnitude (vForce)
            var mag = [Float](repeating: 0, count: winSize/2)
            var n = Int32(mag.count)
            vvsqrtf(&mag, mag2, &n)

            // log compression: log(mag + 1)
            var one: Float = 1.0
            vDSP_vsadd(mag, 1, &one, &mag, 1, vDSP_Length(mag.count))
            var nLog = n
            vvlogf(&mag, mag, &nLog)

            out[t] = mag
        }
        return out
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
        
        // Apply amplitude detection to adjust endpoints programmatically
        for i in 0..<markers.count - 1 {
            if markers[i].group == nil { // Only for transient markers
                let nextPosition = markers[i + 1].samplePosition
                updateRegionEndpoint(markerIndex: i, newEndPosition: nextPosition, isUserAction: false)
            }
        }
    }
    
    func clearDetectedTransients() {
        // Remove all markers that were created from transient detection (those without groups)
        markers.removeAll { marker in
            marker.group == nil && transientMarkers.contains(marker.samplePosition)
        }
        transientMarkers.removeAll()
        hasDetectedTransients = false
    }
    
    func deleteTransientsInRange(_ range: ClosedRange<Int>) {
        // Find all transient markers in the range
        let markersToDelete = markers.filter { marker in
            marker.group == nil && range.contains(marker.samplePosition)
        }
        
        // Remove from transientMarkers set
        for marker in markersToDelete {
            transientMarkers.remove(marker.samplePosition)
        }
        
        // Remove from markers array
        markers.removeAll { marker in
            markersToDelete.contains { $0.id == marker.id }
        }
        
        print("Deleted \(markersToDelete.count) transient markers in selected range")
    }
    
    func startTransientInspection() {
        // Include ALL markers
        guard !markers.isEmpty else { return }
        
        print("DEBUG: Starting inspection with \(markers.count) total markers")
        
        isInspectingTransients = true
        
        // Ensure we have a valid current index
        if currentTransientIndex >= markers.count {
            currentTransientIndex = 0
        }
        
        // Force view update and then focus on the transient
        objectWillChange.send()
        
        // Add a small delay to ensure SwiftUI has processed the state change
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            print("DEBUG: Focusing on transient at index \(self.currentTransientIndex)")
            self.focusOnTransient(at: self.currentTransientIndex)
            // Force another update after focusing
            self.objectWillChange.send()
        }
    }
    
    func stopTransientInspection() {
        isInspectingTransients = false
        // Zoom out to show entire file
        zoomLevel = 1.0
        scrollOffset = 0.0
        // Keep currentTransientIndex so we can resume where we left off
    }
    
    func mergeWithNextRegion() {
        guard isInspectingTransients else { return }
        let sortedTransients = Array(transientMarkers).sorted()
        guard currentTransientIndex < sortedTransients.count - 1 else { return }
        
        // Get current and next transient positions
        let currentTransientPosition = sortedTransients[currentTransientIndex]
        let nextTransientPosition = sortedTransients[currentTransientIndex + 1]
        
        // Find the current marker
        if let currentMarkerIndex = markers.firstIndex(where: { $0.samplePosition == currentTransientPosition }) {
            // Calculate the end position of the next region
            let nextRegionEnd: Int
            if currentTransientIndex + 1 < sortedTransients.count - 1 {
                // There's another transient after the next one
                nextRegionEnd = sortedTransients[currentTransientIndex + 2]
            } else {
                // The next region extends to the end of the file
                nextRegionEnd = totalSamples
            }
            
            // Check if the next marker has a custom end position
            if let nextMarkerIndex = markers.firstIndex(where: { $0.samplePosition == nextTransientPosition }),
               let customEnd = markers[nextMarkerIndex].customEndPosition {
                // Adopt the custom end position from the next marker
                markers[currentMarkerIndex].customEndPosition = customEnd
            } else {
                // Set the end position to where the next region would have ended
                markers[currentMarkerIndex].customEndPosition = nextRegionEnd
            }
        }
        
        // Find and remove the next marker
        if let nextMarkerIndex = markers.firstIndex(where: { $0.samplePosition == nextTransientPosition }) {
            deleteMarker(at: nextMarkerIndex)
        }
    }
    
    func mergeWithPreviousRegion() {
        guard isInspectingTransients else { return }
        let sortedTransients = Array(transientMarkers).sorted()
        guard currentTransientIndex > 0 else { return }
        
        // Get current and previous transient positions
        let currentTransientPosition = sortedTransients[currentTransientIndex]
        let previousTransientPosition = sortedTransients[currentTransientIndex - 1]
        
        // Find the previous marker
        if let previousMarkerIndex = markers.firstIndex(where: { $0.samplePosition == previousTransientPosition }) {
            // Check if the current marker has a custom end position
            if let currentMarkerIndex = markers.firstIndex(where: { $0.samplePosition == currentTransientPosition }),
               let customEnd = markers[currentMarkerIndex].customEndPosition {
                // Adopt the custom end position from the current marker
                markers[previousMarkerIndex].customEndPosition = customEnd
            } else {
                // Calculate the end position
                let currentRegionEnd: Int
                if currentTransientIndex < sortedTransients.count - 1 {
                    // There's another transient after the current one
                    currentRegionEnd = sortedTransients[currentTransientIndex + 1]
                } else {
                    // The current region extends to the end of the file
                    currentRegionEnd = totalSamples
                }
                markers[previousMarkerIndex].customEndPosition = currentRegionEnd
            }
        }
        
        // Find and remove the current marker
        if let currentMarkerIndex = markers.firstIndex(where: { $0.samplePosition == currentTransientPosition }) {
            deleteMarker(at: currentMarkerIndex)
        }
        
        // Move to the previous region
        previousTransient()
    }
    
    func nextTransient() {
        guard !markers.isEmpty else { return }
        currentTransientIndex = (currentTransientIndex + 1) % markers.count
        focusOnTransient(at: currentTransientIndex)
    }
    
    func previousTransient() {
        guard !markers.isEmpty else { return }
        currentTransientIndex = (currentTransientIndex - 1 + markers.count) % markers.count
        focusOnTransient(at: currentTransientIndex)
    }
    
    private func focusOnTransient(at index: Int) {
        // Get all markers sorted by position
        let allMarkersSorted = markers.sorted { $0.samplePosition < $1.samplePosition }
        guard index >= 0 && index < allMarkersSorted.count else { return }
        
        let currentMarker = allMarkersSorted[index]
        let transientPosition = currentMarker.samplePosition
        
        print("focusOnTransient - index: \(index), transientPosition: \(transientPosition)")
        print("Actual marker positions: \(allMarkersSorted.map { $0.samplePosition })")
        
        // Find the end position (next transient or end of file)
        let endPosition: Int
        if let customEnd = currentMarker.customEndPosition {
            endPosition = customEnd
        } else if index < allMarkersSorted.count - 1 {
            endPosition = allMarkersSorted[index + 1].samplePosition
        } else {
            endPosition = totalSamples
        }
        
        // Calculate the region size
        let regionSize = endPosition - transientPosition
        let regionSizeRatio = Double(regionSize) / Double(totalSamples)
        
        // Set zoom to show the entire region with some padding
        let paddingRatio = 0.2 // 20% padding on each side
        let targetZoom = 1.0 / (regionSizeRatio * (1.0 + paddingRatio * 2))
        zoomLevel = min(targetZoom, 50.0) // Cap at 50x zoom
        
        // Center the view on the region
        let regionCenter = Double(transientPosition + regionSize / 2) / Double(totalSamples)
        scrollOffset = max(0, min(1.0 - 1.0/zoomLevel, regionCenter - 0.5/zoomLevel))
    }
    
    func updateTransientOffsets(oldOffset: Double, newOffset: Double) {
        guard hasDetectedTransients else { return }
        
        // Calculate the sample rate and offset difference
        let sampleRate = self.sampleRate
        let sr = self.sampleRate          // ← add this line
        let oldOffsetSamples = Int(oldOffset * sr / 1000.0)
        let newOffsetSamples = Int(newOffset * sr / 1000.0)
        let offsetDifference = newOffsetSamples - oldOffsetSamples
        
        // Update transient markers set
        var newTransientMarkers: Set<Int> = []
        for position in transientMarkers {
            // Move marker back to original position then apply new offset
            let originalPosition = position - oldOffsetSamples
            let newPosition = max(0, originalPosition + newOffsetSamples)
            newTransientMarkers.insert(newPosition)
        }
        transientMarkers = newTransientMarkers
        
        // Update actual markers array
        for i in markers.indices {
            if markers[i].group == nil {
                let oldPosition = markers[i].samplePosition
                let originalPosition = oldPosition - oldOffsetSamples
                let newPosition = max(0, originalPosition + newOffsetSamples)
                markers[i].samplePosition = newPosition
            }
        }
        
        // Sort markers by position
        markers.sort { $0.samplePosition < $1.samplePosition }
    }
    
    func updateTransientThreshold(_ newThreshold: Double) {
        print("Threshold slider changed to: \(newThreshold)")
        transientThreshold = newThreshold
        if hasDetectedTransients || !transientMarkers.isEmpty {
            print("Re-detecting transients with new threshold")
            // Clear existing transient markers before re-detecting
            clearDetectedTransients()
            hasDetectedTransients = true
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
    
    func playMarkerRegion(marker: Marker) {
        guard let player = audioPlayer, let buffer = sampleBuffer else { return }
        
        // Use custom end position if available
        let endPosition: Int
        if let customEnd = marker.customEndPosition {
            endPosition = customEnd
        } else {
            // Find the next marker position or use end of file
            let allMarkerPositions = markers.map { $0.samplePosition }.sorted()
            let nextMarkerIndex = allMarkerPositions.firstIndex { $0 > marker.samplePosition }
            if let nextIndex = nextMarkerIndex {
                endPosition = allMarkerPositions[nextIndex]
            } else {
                endPosition = buffer.samples.count
            }
        }
        
        // Play the region
        let sampleRate = player.format.sampleRate
        let startTime = TimeInterval(marker.samplePosition) / sampleRate
        let endTime = TimeInterval(endPosition) / sampleRate
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
            if player.isPlaying {
                player.stop()
                self.isPlaying = false
                self.stopPlayheadTracking()
            }
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
    @State private var isTargeted = false
    
    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isTargeted ? Color.blue : Color.gray.opacity(0.3), lineWidth: isTargeted ? 2 : 1)
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
                                
                                // Draw markers or focused region
                                if viewModel.isInspectingTransients {
                                    // In inspection mode, show current and next regions
                                    // Include ALL markers (both with and without groups)
                                    let allMarkersSorted = viewModel.markers
                                        .sorted { $0.samplePosition < $1.samplePosition }
                                    
                                    print("DEBUG: Inspection mode - found \(allMarkersSorted.count) total markers")
                                    print("DEBUG: currentTransientIndex = \(viewModel.currentTransientIndex)")
                                    
                                    // Next region
                                    let nextIndex = viewModel.currentTransientIndex + 1
                                    if nextIndex < allMarkersSorted.count {
                                        let nextMarker = allMarkersSorted[nextIndex]

                                        let nextEndPosition = endOfRegion(after: nextMarker,
                                                                          markers: viewModel.markers,
                                                                          totalSamples: viewModel.totalSamples)

                                        let nextStartX = viewModel.xPosition(for: nextMarker.samplePosition, in: size.width)
                                        let nextEndX   = viewModel.xPosition(for: nextEndPosition,       in: size.width)

                                        if nextStartX <= size.width && nextEndX >= 0 {
                                            let x = max(0, nextStartX)
                                            let w = min(size.width, nextEndX) - x
                                            let r = CGRect(x: x, y: 0, width: w, height: size.height)
                                            context.fill(Path(r), with: .color(.orange.opacity(0.15)))
                                        }

                                        if (0...size.width).contains(nextStartX) {
                                            var line = Path(); line.move(to: .init(x: nextStartX, y: 0)); line.addLine(to: .init(x: nextStartX, y: size.height))
                                            context.stroke(line, with: .color(.orange), lineWidth: 1)
                                        }
                                        if (0...size.width).contains(nextEndX) {
                                            var line = Path(); line.move(to: .init(x: nextEndX, y: 0)); line.addLine(to: .init(x: nextEndX, y: size.height))
                                            context.stroke(line, with: .color(.orange), lineWidth: 1)
                                        }
                                    }
                                    
                                    // Current region
                                    if viewModel.currentTransientIndex >= 0,
                                       viewModel.currentTransientIndex < allMarkersSorted.count {
                                        let marker = allMarkersSorted[viewModel.currentTransientIndex]
                                        
                                        print("DEBUG: Drawing current region for marker at position \(marker.samplePosition)")

                                        let endPosition = endOfRegion(after: marker,
                                                                      markers: viewModel.markers,
                                                                      totalSamples: viewModel.totalSamples)
                                        
                                        print("DEBUG: Region from \(marker.samplePosition) to \(endPosition)")

                                        let startX = viewModel.xPosition(for: marker.samplePosition, in: size.width)
                                        let endX   = viewModel.xPosition(for: endPosition,          in: size.width)
                                        
                                        print("DEBUG: Drawing positions - startX: \(startX), endX: \(endX), width: \(size.width)")

                                        if startX <= size.width && endX >= 0 {
                                            let x = max(0, startX)
                                            let w = min(size.width, endX) - x
                                            let r = CGRect(x: x, y: 0, width: w, height: size.height)
                                            context.fill(Path(r), with: .color(.purple.opacity(0.2)))
                                        }

                                        if (0...size.width).contains(startX) {
                                            var line = Path(); line.move(to: .init(x: startX, y: 0)); line.addLine(to: .init(x: startX, y: size.height))
                                            context.stroke(line, with: .color(.purple), lineWidth: 2)
                                        }
                                        if (0...size.width).contains(endX) {
                                            var line = Path(); line.move(to: .init(x: endX, y: 0)); line.addLine(to: .init(x: endX, y: size.height))
                                            context.stroke(line, with: .color(.purple), lineWidth: 2)
                                        }
                                    }
                                    
                                } else {
                                    // Normal mode - show all markers if enabled or in inspection mode
                                    if viewModel.showTransientMarkers || viewModel.isInspectingTransients {
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
                                .highPriorityGesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            // Check for cmd key for marker add/remove
                                            if NSEvent.modifierFlags.contains(.command) && viewModel.draggingMarkerIndex == nil {
                                                // This is a cmd+click/drag - handle it as marker operation
                                                if abs(value.translation.width) < 5 && abs(value.translation.height) < 5 {
                                                    print("Cmd+click @ \(value.location.x)")
                                                    // In inspection mode, don't handle marker deletion here - let the handles do it
                                                    if !viewModel.isInspectingTransients {
                                                        // Check if we're near an existing marker
                                                        if let markerIndex = viewModel.findMarkerNearPosition(x: value.location.x, width: geometry.size.width) {
                                                            // Remove the marker
                                                            let marker = viewModel.markers[markerIndex]
                                                            if marker.group == nil {
                                                                viewModel.transientMarkers.remove(marker.samplePosition)
                                                            }
                                                            viewModel.markers.remove(at: markerIndex)
                                                        } else {
                                                            // Add a new marker
                                                            viewModel.addMarker(atX: value.location.x, inWidth: geometry.size.width)
                                                        }
                                                        viewModel.draggingMarkerIndex = -1 // Signal that we handled cmd+click
                                                    }
                                                }
                                                return
                                            }
                                            
                                            if viewModel.draggingMarkerIndex == nil {
                                                // Check if we're near a transient marker handle (at the top)
                                                if value.startLocation.y < 20 {
                                                    viewModel.draggingMarkerIndex = viewModel.findMarkerNearPosition(
                                                        x: value.startLocation.x,
                                                        width: geometry.size.width,
                                                        tolerance: 10
                                                    )
                                                }
                                            }
                                            
                                            if viewModel.draggingMarkerIndex == -1 {
                                                // We already handled cmd+click, do nothing
                                                return
                                            } else if let dragIndex = viewModel.draggingMarkerIndex {
                                                viewModel.moveMarker(at: dragIndex, toX: value.location.x, width: geometry.size.width)
                                            } else {
                                                // Only create selection on drag, not on single click
                                                if abs(value.translation.width) > 5 || abs(value.translation.height) > 5 {
                                                    viewModel.updateTempSelection(
                                                        startX: value.startLocation.x,
                                                        currentX: value.location.x,
                                                        width: geometry.size.width
                                                    )
                                                }
                                            }
                                        }
                                        .onEnded { value in
                                            if viewModel.draggingMarkerIndex == -1 {
                                                // Reset cmd+click flag
                                                viewModel.draggingMarkerIndex = nil
                                            } else if viewModel.draggingMarkerIndex != nil {
                                                viewModel.draggingMarkerIndex = nil
                                            } else if abs(value.translation.width) < 5 && abs(value.translation.height) < 5 {
                                                // This was effectively a tap, not a drag
                                                // Clear any existing selection
                                                viewModel.clearSelection()
                                            } else {
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
        .background(
            ScrollWheelHandler(
                onScroll: { deltaX, deltaY in
                    // Handle both horizontal and vertical scrolling with improved sensitivity
                    let horizontalScroll = Double(deltaX) / 3000.0  // Increased sensitivity
                    let verticalScroll = Double(deltaY) / 3000.0
                    
                    // Use whichever has larger magnitude
                    if abs(deltaX) > 0.1 || abs(deltaY) > 0.1 {  // Lower threshold
                        let scrollAmount = abs(deltaX) > abs(deltaY) ? horizontalScroll : -verticalScroll
                        viewModel.scroll(by: scrollAmount) // Removed negative for flipped scrolling
                    }
                },
                zoomLevel: $viewModel.zoomLevel,
                onZoom: { factor, location, width in
                    viewModel.zoom(by: factor, at: location, in: width)
                }
            )
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item, error) in
                if let error = error {
                    print("Error loading dropped file: \(error)")
                    return
                }
                
                var fileURL: URL?
                if let urlData = item as? Data {
                    fileURL = URL(dataRepresentation: urlData, relativeTo: nil)
                } else if let url = item as? URL {
                    fileURL = url
                }
                
                if let url = fileURL, url.pathExtension.lowercased() == "wav" {
                    DispatchQueue.main.async {
                        // Access the file directly without security-scoped resource
                        viewModel.importWAV(from: url)
                    }
                } else {
                    print("Dropped file is not a WAV file or URL could not be extracted")
                }
            }
            return true
        }
        .overlay(
            Group {
                if isTargeted {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.blue.opacity(0.1))
                            .allowsHitTesting(false)
                        Text("Drop WAV file here")
                            .font(.headline)
                            .foregroundColor(.blue)
                    }
                }
            }
        )
    }
}

// MARK: - Minimap Waveform with auto Y-scale
struct MinimapWaveform: View {
    let samples: SampleBuffer
    
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard !samples.samples.isEmpty else { return }
                
                // Downsample for minimap (we don't need full resolution)
                let targetSampleCount = min(Int(size.width * 2), samples.samples.count)
                let step = max(1, samples.samples.count / targetSampleCount)
                var displaySamples: [Float] = []
                
                for i in stride(from: 0, to: samples.samples.count, by: step) {
                    // Take max of the chunk for better visualization
                    let endIndex = min(i + step, samples.samples.count)
                    let chunk = samples.samples[i..<endIndex]
                    let maxValue = chunk.map { abs($0) }.max() ?? 0
                    displaySamples.append(maxValue)
                }
                
                // Find max amplitude for auto-scaling
                let maxAmplitude = displaySamples.max() ?? 1.0
                let scale = maxAmplitude > 0 ? 0.9 / maxAmplitude : 1.0
                
                let midY = size.height / 2
                let sampleStep = size.width / CGFloat(displaySamples.count - 1)
                
                // Create waveform path
                var path = Path()
                
                for i in displaySamples.indices {
                    let x = CGFloat(i) * sampleStep
                    let amplitude = CGFloat(displaySamples[i]) * CGFloat(scale) * midY
                    
                    // Draw vertical line for each sample
                    path.move(to: CGPoint(x: x, y: midY - amplitude))
                    path.addLine(to: CGPoint(x: x, y: midY + amplitude))
                }
                
                context.stroke(path, with: .color(.gray.opacity(0.7)), lineWidth: 0.5)
            }
        }
    }
}

// MARK: - Minimap for navigation
struct MinimapView: View {
    @ObservedObject var viewModel: EnhancedAudioViewModel
    @State private var isDraggingLeft = false
    @State private var isDraggingRight = false
    @State private var isDraggingIndicator = false
    @State private var dragStartZoom: Double = 1.0
    @State private var dragStartOffset: Double = 0.0
    @State private var dragStartIndicatorOffset: Double = -1.0
    @State private var dragStartIndicatorWidth: CGFloat = 0
    @State private var dragStartLeftPx: CGFloat = 0
    @State private var dragStartRightPx: CGFloat = 0
    
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            
            Color.clear
                .overlay(
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.1))
                        
                        if let buffer = viewModel.sampleBuffer {
                            MinimapWaveform(samples: buffer)
                                .foregroundColor(.gray.opacity(0.7))
                                .allowsHitTesting(false)
                        }
                        
                        // Transient/marker tick lines
                        Canvas { context, size in
                            for marker in viewModel.markers {
                                let markerPosition = Double(marker.samplePosition) / Double(viewModel.totalSamples)
                                let x = markerPosition * size.width
                                var line = Path()
                                line.move(to: CGPoint(x: x, y: 0))
                                line.addLine(to: CGPoint(x: x, y: size.height))
                                let c: Color = marker.group == nil ? .red.opacity(0.5) : .green.opacity(0.5)
                                context.stroke(line, with: .color(c), lineWidth: 0.5)
                            }
                        }
                        .allowsHitTesting(false)
                        
                        let indicatorWidth = max(20, width / CGFloat(viewModel.zoomLevel))
                        let indicatorOffset = CGFloat(viewModel.scrollOffset) * width + indicatorWidth / 2 - width / 2
                        
                        let indicatorRatio = indicatorWidth / width
                        let edgeZoneWidth: CGFloat = (indicatorRatio < 0.1) ? min(4, indicatorWidth * 0.3) : 8
                        
                        // Indicator + edge handles
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.blue.opacity(0.3))
                                .stroke(Color.blue, lineWidth: 1)
                                .frame(width: indicatorWidth, height: geometry.size.height)
                            
                            // Left edge handle
                            Rectangle()
                                .fill(Color.blue.opacity(0.001))
                                .frame(width: edgeZoneWidth, height: geometry.size.height)
                                .contentShape(Rectangle())
                                .offset(x: -indicatorWidth/2 + edgeZoneWidth/2)
                                .cursor(NSCursor.resizeLeftRight)
                                .highPriorityGesture(
                                    DragGesture(minimumDistance: 1, coordinateSpace: .named("minimap"))
                                        .onChanged { value in
                                            if !isDraggingLeft {
                                                isDraggingLeft = true
                                                dragStartZoom = viewModel.zoomLevel
                                                dragStartOffset = viewModel.scrollOffset
                                                dragStartIndicatorWidth = width / CGFloat(viewModel.zoomLevel)
                                                dragStartLeftPx = CGFloat(dragStartOffset) * width
                                                dragStartRightPx = dragStartLeftPx + dragStartIndicatorWidth
                                            }
                                            let minWidth: CGFloat = 20
                                            let newLeftPx = min(max(0, value.location.x), dragStartRightPx - minWidth)
                                            let newWidth = dragStartRightPx - newLeftPx
                                            let newZoom = width / newWidth
                                            
                                            if newZoom >= 1, newZoom <= 500 {
                                                viewModel.zoomLevel = newZoom
                                                let maxOff = 1.0 - 1.0 / newZoom
                                                viewModel.scrollOffset = max(0, min(maxOff, Double(newLeftPx / width)))
                                            }
                                        }
                                        .onEnded { _ in
                                            isDraggingLeft = false
                                        }
                                )
                            
                            // Right edge handle
                            Rectangle()
                                .fill(Color.blue.opacity(0.001))
                                .frame(width: edgeZoneWidth, height: geometry.size.height)
                                .contentShape(Rectangle())
                                .offset(x: indicatorWidth/2 - edgeZoneWidth/2)
                                .cursor(NSCursor.resizeLeftRight)
                                .highPriorityGesture(
                                    DragGesture(minimumDistance: 1, coordinateSpace: .named("minimap"))
                                        .onChanged { value in
                                            if !isDraggingRight {
                                                isDraggingRight = true
                                                dragStartZoom = viewModel.zoomLevel
                                                dragStartOffset = viewModel.scrollOffset
                                                dragStartIndicatorWidth = width / CGFloat(viewModel.zoomLevel)
                                                dragStartLeftPx = CGFloat(dragStartOffset) * width
                                                dragStartRightPx = dragStartLeftPx + dragStartIndicatorWidth
                                            }
                                            let minWidth: CGFloat = 20
                                            let newRightPx = max(min(width, value.location.x), dragStartLeftPx + minWidth)
                                            let newWidth = newRightPx - dragStartLeftPx
                                            let newZoom = width / newWidth
                                            
                                            if newZoom >= 1, newZoom <= 500 {
                                                viewModel.zoomLevel = newZoom
                                                let maxOff = 1.0 - 1.0 / newZoom
                                                viewModel.scrollOffset = max(0, min(maxOff, Double(dragStartLeftPx / width)))
                                            }
                                        }
                                        .onEnded { _ in
                                            isDraggingRight = false
                                        }
                                )
                        }
                        .frame(width: indicatorWidth, height: geometry.size.height)
                        .offset(x: indicatorOffset)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard !isDraggingLeft && !isDraggingRight else { return }
                                    guard viewModel.zoomLevel > 1.0 else { return }
                                    if !isDraggingIndicator {
                                        isDraggingIndicator = true
                                        dragStartIndicatorOffset = viewModel.scrollOffset
                                    }
                                    let dragDelta = value.translation.width / width
                                    let newOffset = dragStartIndicatorOffset + Double(dragDelta)
                                    let maxScrollOffset = 1.0 - (1.0 / viewModel.zoomLevel)
                                    viewModel.scrollOffset = max(0, min(maxScrollOffset, newOffset))
                                }
                                .onEnded { _ in
                                    dragStartIndicatorOffset = -1
                                    isDraggingIndicator = false
                                }
                        )
                    }
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                )
                .coordinateSpace(name: "minimap")
                .contentShape(Rectangle())
                // ✅ Single-tap with location (SpatialTapGesture)
                .simultaneousGesture(
                    SpatialTapGesture()
                        .onEnded { (evt: SpatialTapGesture.Value) in
                            let location = evt.location
                            let indicatorWidth = width / CGFloat(viewModel.zoomLevel)
                            let indicatorStart = CGFloat(viewModel.scrollOffset) * width
                            let indicatorEnd = indicatorStart + indicatorWidth
                            
                            if location.x < indicatorStart || location.x > indicatorEnd {
                                guard viewModel.zoomLevel > 1.0 else { return }
                                let clampedPx = min(max(0, location.x - indicatorWidth / 2), width - indicatorWidth)
                                let targetOffset = clampedPx / (width - indicatorWidth)
                                let maxScrollOffset = 1.0 - (1.0 / viewModel.zoomLevel)
                                viewModel.scrollOffset = max(0, min(maxScrollOffset, Double(targetOffset)))
                            }
                        }
                )
        }
        .frame(height: 60)
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
            
            // Transient offset controls
            HStack {
                Text("Transient Offset (ms):")
                Slider(
                    value: Binding(
                        get: { viewModel.transientOffsetMs },
                        set: { newValue in
                            let oldValue = viewModel.transientOffsetMs
                            viewModel.transientOffsetMs = newValue
                            // If we have detected transients, update their positions
                            if viewModel.hasDetectedTransients {
                                viewModel.updateTransientOffsets(oldOffset: oldValue, newOffset: newValue)
                            }
                        }
                    ),
                    in: 0...20.0
                )
                .frame(width: 200)
                .disabled(viewModel.sampleBuffer == nil)
                Text(String(format: "%.1f ms", viewModel.transientOffsetMs))
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
    }
}

// MARK: - ScrollWheel Handler
struct ScrollWheelHandler: NSViewRepresentable {
    let onScroll: (CGFloat, CGFloat) -> Void
    @Binding var zoomLevel: Double
    let onZoom: (Double, CGFloat, CGFloat) -> Void  // factor, location, width
    
    class Coordinator: NSObject {
        var parent: ScrollWheelHandler
        var eventMonitor: Any?
        var magnificationMonitor: Any?
        var viewBounds: NSRect = .zero
        
        init(parent: ScrollWheelHandler) {
            self.parent = parent
        }
        
        deinit {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let monitor = magnificationMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        return Coordinator(parent: self)
    }
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        
        // Add local event monitor for scroll wheel events
        context.coordinator.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
            // Check if the event is within our view
            if let window = view.window {
                let locationInWindow = event.locationInWindow
                let locationInView = view.convert(locationInWindow, from: nil)
                if view.bounds.contains(locationInView) {
                    print("ScrollWheel event captured - deltaX: \(event.scrollingDeltaX), deltaY: \(event.scrollingDeltaY)")
                    context.coordinator.parent.onScroll(event.scrollingDeltaX, event.scrollingDeltaY)
                }
            }
            return event
        }
        
        // Add magnification (pinch) gesture monitor
        context.coordinator.magnificationMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify]) { event in
            // Check if the event is within our view
            if let window = view.window {
                let locationInWindow = event.locationInWindow
                let locationInView = view.convert(locationInWindow, from: nil)
                if view.bounds.contains(locationInView) {
                    print("Magnification event captured - magnification: \(event.magnification), location: \(locationInView)")
                    // Apply zoom centered at cursor position
                    let zoomFactor = 1.0 + Double(event.magnification)
                    context.coordinator.viewBounds = view.bounds
                    context.coordinator.parent.onZoom(zoomFactor, locationInView.x, view.bounds.width)
                }
            }
            return event
        }
        
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // No updates needed
    }
}
