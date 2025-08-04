import SwiftUI
import AVFoundation

struct AmplitudeGroupSuggestionView: View {
    @ObservedObject var audioViewModel: EnhancedAudioViewModel
    @Environment(\.dismiss) var dismiss
    
    @State private var windowLengthMs: Double = 256
    @State private var suggestedGrouping: [Int: [Marker]] = [:]
    @State private var showingSuggestions = false
    @State private var isAnalyzing = false
    @State private var expandedGroups: Set<Int> = []
    @State private var playingMarkers: Set<UUID> = []
    
    // Testing mode states
    @State private var isTestingMode = false
    @State private var manualGrouping: [Int: [Marker]] = [:]
    @State private var testSession: GroupingTestSession? = nil
    @State private var showingExportDialog = false
    
    private let analyzer = SpectralGroupingAnalyzer()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Spectral-Based Group Assignment")
                .font(.title2)
                .fontWeight(.semibold)
            
            if !showingSuggestions {
                // Initial configuration
                VStack(spacing: 20) {
                    Text("Spectral Analysis Configuration")
                        .font(.headline)
                    
                    Text("The system will automatically determine the optimal number of velocity layers and round-robins based on your samples.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    VStack(alignment: .leading, spacing: 16) {
                        // Testing mode toggle
                        Toggle("Testing Mode", isOn: $isTestingMode)
                            .help("Enable to manually group samples before running auto-suggestion for comparison")
                        
                        if isTestingMode {
                            Text("In testing mode, first assign groups manually using the main interface, then run analysis to compare.")
                                .font(.caption)
                                .foregroundColor(.orange)
                                .padding(.vertical, 4)
                        }
                        
                        Divider()
                        
                        // Window length
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Analysis Window:")
                                Spacer()
                                Text("\(Int(windowLengthMs)) ms")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $windowLengthMs, in: 100...500, step: 50) {
                                Text("Window")
                            }
                            .help("Length of audio to analyze from each sample's attack")
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                    
                    HStack {
                        Button("Cancel") {
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                        
                        Spacer()
                        
                        Button("Analyze") {
                            if isTestingMode {
                                captureManualGroupingAndAnalyze()
                            } else {
                                analyzeWithSpectralFeatures()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isAnalyzing)
                    }
                }
            } else {
                // Suggested grouping display
                VStack(spacing: 16) {
                    Text("Suggested Grouping")
                        .font(.headline)
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(suggestedGrouping.keys.sorted(), id: \.self) { groupNum in
                                GroupSuggestionRow(
                                    groupNumber: groupNum,
                                    markers: suggestedGrouping[groupNum] ?? [],
                                    isExpanded: expandedGroups.contains(groupNum),
                                    playingMarkers: playingMarkers,
                                    audioViewModel: audioViewModel,
                                    onToggleExpand: {
                                        if expandedGroups.contains(groupNum) {
                                            expandedGroups.remove(groupNum)
                                        } else {
                                            expandedGroups.insert(groupNum)
                                        }
                                    },
                                    onPlayMarker: { marker in
                                        playMarker(marker)
                                    }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                    
                    HStack {
                        Button("Adjust") {
                            showingSuggestions = false
                        }
                        .buttonStyle(.bordered)
                        
                        Spacer()
                        
                        Button("Apply Grouping") {
                            applyGrouping()
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        
                        if isTestingMode && testSession != nil {
                            Button("Export Analysis") {
                                showingExportDialog = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: 500, height: 400)
        .overlay {
            if isAnalyzing {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                ProgressView("Analyzing amplitudes...")
                    .padding()
                    .background(Color.white)
                    .cornerRadius(8)
            }
        }
        .onDisappear {
            // Clean up any ongoing playback
            if !playingMarkers.isEmpty {
                audioViewModel.stopPlayback()
                playingMarkers.removeAll()
            }
        }
        .fileExporter(
            isPresented: $showingExportDialog,
            document: TestSessionDocument(session: testSession),
            contentType: .json,
            defaultFilename: "spectral_grouping_analysis_\(Date().timeIntervalSince1970).json"
        ) { result in
            switch result {
            case .success(let url):
                print("Analysis exported to: \(url)")
                if let session = testSession {
                    analyzer.printDetailedAnalysis(session)
                }
            case .failure(let error):
                print("Export failed: \(error)")
            }
        }
    }
    
    private func analyzeWithSpectralFeatures() {
        isAnalyzing = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Create temporary audio files for each region
                var regionURLs: [(marker: Marker, url: URL)] = []
                let tempDir = FileManager.default.temporaryDirectory
                
                guard let buffer = audioViewModel.sampleBuffer else { return }
                let sortedMarkers = audioViewModel.markers.sorted { $0.samplePosition < $1.samplePosition }
                
                for (index, marker) in sortedMarkers.enumerated() {
                    let startPos = marker.samplePosition
                    let endPos: Int
                    
                    if let customEnd = marker.customEndPosition {
                        endPos = customEnd
                    } else if index < sortedMarkers.count - 1 {
                        endPos = sortedMarkers[index + 1].samplePosition
                    } else {
                        endPos = audioViewModel.zoneStartOffset + audioViewModel.zoneTotalSamples
                    }
                    
                    // Extract region samples
                    let regionLength = endPos - startPos
                    guard regionLength > 0 else { continue }
                    
                    let regionSamples = Array(buffer.samples[startPos..<min(endPos, buffer.samples.count)])
                    
                    // Create temporary audio file
                    let tempURL = tempDir.appendingPathComponent("region_\(marker.id.uuidString).wav")
                    
                    // Write samples to WAV file
                    if let audioFile = try? AVAudioFile(forWriting: tempURL, settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: audioViewModel.sampleRate,
                        AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true
                    ]) {
                        let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: AVAudioFrameCount(regionSamples.count))!
                        audioBuffer.frameLength = AVAudioFrameCount(regionSamples.count)
                        
                        if let channelData = audioBuffer.floatChannelData {
                            for (i, sample) in regionSamples.enumerated() {
                                channelData[0][i] = sample
                            }
                        }
                        
                        try audioFile.write(from: audioBuffer)
                        regionURLs.append((marker: marker, url: tempURL))
                    }
                }
                
                // Use automatic spectral analysis to group samples
                let urls = regionURLs.map { $0.url }
                let groups = try autoGroupSamplesIntoPseudoVelocityLayers(
                    urls: urls,
                    windowMs: windowLengthMs
                )
                
                // Convert results back to markers
                var grouping: [Int: [Marker]] = [:]
                for (groupIndex, groupURLs) in groups.enumerated() {
                    grouping[groupIndex] = []
                    for url in groupURLs {
                        if let item = regionURLs.first(where: { $0.url == url }) {
                            grouping[groupIndex]?.append(item.marker)
                        }
                    }
                }
                
                // Clean up temporary files
                for item in regionURLs {
                    try? FileManager.default.removeItem(at: item.url)
                }
                
                DispatchQueue.main.async {
                    suggestedGrouping = grouping
                    showingSuggestions = true
                    isAnalyzing = false
                }
                
            } catch {
                print("Error analyzing with spectral features: \(error)")
                DispatchQueue.main.async {
                    isAnalyzing = false
                }
            }
        }
    }
    
    private func analyzeAmplitudes() {
        isAnalyzing = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            // Calculate max amplitude for each region
            var regionAmplitudes: [(marker: Marker, maxAmplitude: Float)] = []
            
            guard let buffer = audioViewModel.sampleBuffer else { return }
            let sortedMarkers = audioViewModel.markers.sorted { $0.samplePosition < $1.samplePosition }
            
            for (index, marker) in sortedMarkers.enumerated() {
                let startPos = marker.samplePosition
                let endPos: Int
                
                if let customEnd = marker.customEndPosition {
                    endPos = customEnd
                } else if index < sortedMarkers.count - 1 {
                    endPos = sortedMarkers[index + 1].samplePosition
                } else {
                    endPos = audioViewModel.zoneStartOffset + audioViewModel.zoneTotalSamples
                }
                
                var maxAmplitude: Float = 0
                for i in startPos..<min(endPos, buffer.count) {
                    maxAmplitude = max(maxAmplitude, abs(buffer.samples[i]))
                }
                
                regionAmplitudes.append((marker: marker, maxAmplitude: maxAmplitude))
            }
            
            // Sort by amplitude
            regionAmplitudes.sort { $0.maxAmplitude > $1.maxAmplitude }
            
            // Use the automatic grouping logic
            let grouping = determineOptimalGroups(from: regionAmplitudes)
            
            DispatchQueue.main.async {
                suggestedGrouping = grouping
                showingSuggestions = true
                isAnalyzing = false
            }
        }
    }
    
    private func determineOptimalGroups(from amplitudes: [(marker: Marker, maxAmplitude: Float)]) -> [Int: [Marker]] {
        // Simple clustering based on amplitude gaps
        var groups: [Int: [Marker]] = [:]
        var currentGroup = 1
        groups[currentGroup] = []
        
        let sortedAmplitudes = amplitudes.sorted { $0.maxAmplitude > $1.maxAmplitude }
        
        for i in 0..<sortedAmplitudes.count {
            groups[currentGroup]?.append(sortedAmplitudes[i].marker)
            
            // Check if there's a significant gap to the next amplitude
            if i < sortedAmplitudes.count - 1 {
                let currentAmp = sortedAmplitudes[i].maxAmplitude
                let nextAmp = sortedAmplitudes[i + 1].maxAmplitude
                let ratio = currentAmp / max(nextAmp, 0.0001)
                
                // If the ratio is greater than 1.5, start a new group
                if ratio > 1.5 {
                    currentGroup += 1
                    groups[currentGroup] = []
                }
            }
        }
        
        // Remove empty groups
        groups = groups.filter { !$0.value.isEmpty }
        
        // Renumber groups
        var renumbered: [Int: [Marker]] = [:]
        for (index, markers) in groups.values.enumerated() {
            renumbered[index + 1] = markers
        }
        
        return renumbered
    }
    
    private func playMarker(_ marker: Marker) {
        if playingMarkers.contains(marker.id) {
            audioViewModel.stopPlayback()
            playingMarkers.remove(marker.id)
        } else {
            // Stop any other playback
            audioViewModel.stopPlayback()
            playingMarkers.removeAll()
            
            // Play this marker
            let sortedMarkers = audioViewModel.markers.sorted { $0.samplePosition < $1.samplePosition }
            
            if let index = sortedMarkers.firstIndex(where: { $0.id == marker.id }) {
                let startPos = marker.samplePosition
                let endPos: Int
                
                if let customEnd = marker.customEndPosition {
                    endPos = customEnd
                } else if index < sortedMarkers.count - 1 {
                    endPos = sortedMarkers[index + 1].samplePosition
                } else {
                    endPos = audioViewModel.zoneStartOffset + audioViewModel.zoneTotalSamples
                }
                
                audioViewModel.tempSelection = startPos...endPos
                audioViewModel.playSelection()
                playingMarkers.insert(marker.id)
                
                // Clear playing state after playback
                let duration = Double(endPos - startPos) / audioViewModel.sampleRate
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                    playingMarkers.remove(marker.id)
                    audioViewModel.tempSelection = nil
                }
            }
        }
    }
    
    private func captureManualGroupingAndAnalyze() {
        isAnalyzing = true
        
        // Capture current manual grouping
        manualGrouping = [:]
        for marker in audioViewModel.markers {
            if let group = marker.group {
                if manualGrouping[group] == nil {
                    manualGrouping[group] = []
                }
                manualGrouping[group]?.append(marker)
            }
        }
        
        // Run analysis with comparison
        Task {
            // Run automatic grouping (which includes analysis)
            let (autoGrouping, analysisData) = await analyzer.runAutomaticGrouping(
                markers: audioViewModel.markers,
                audioViewModel: audioViewModel,
                windowMs: windowLengthMs
            )
            
            // Convert groupings to string IDs
            var manualStringGrouping: [Int: [String]] = [:]
            for (group, markers) in manualGrouping {
                manualStringGrouping[group] = markers.map { $0.id.uuidString }
            }
            
            // Compare groupings
            let metrics = analyzer.compareGroupings(
                manual: manualStringGrouping,
                automatic: autoGrouping,
                analysisData: analysisData
            )
            
            // Create test session
            let session = GroupingTestSession(
                windowLengthMs: windowLengthMs,
                sampleCount: audioViewModel.markers.count,
                samples: analysisData,
                manualGrouping: manualStringGrouping,
                automaticGrouping: autoGrouping,
                comparisonMetrics: metrics
            )
            
            // Convert automatic grouping back to markers
            var markerGrouping: [Int: [Marker]] = [:]
            for (group, sampleIds) in autoGrouping {
                markerGrouping[group] = []
                for id in sampleIds {
                    if let marker = audioViewModel.markers.first(where: { $0.id.uuidString == id }) {
                        markerGrouping[group]?.append(marker)
                    }
                }
            }
            
            await MainActor.run {
                self.testSession = session
                self.suggestedGrouping = markerGrouping
                self.showingSuggestions = true
                self.isAnalyzing = false
                
                // Print analysis to console
                analyzer.printDetailedAnalysis(session)
            }
        }
    }
    
    private func applyGrouping() {
        // Apply the suggested grouping to the markers
        for (groupNum, markers) in suggestedGrouping {
            for marker in markers {
                if let index = audioViewModel.markers.firstIndex(where: { $0.id == marker.id }) {
                    audioViewModel.markers[index].group = groupNum + 1  // Groups start at 1 in the UI
                }
            }
        }
    }
}

struct GroupSuggestionRow: View {
    let groupNumber: Int
    let markers: [Marker]
    let isExpanded: Bool
    let playingMarkers: Set<UUID>
    @ObservedObject var audioViewModel: EnhancedAudioViewModel
    let onToggleExpand: () -> Void
    let onPlayMarker: (Marker) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Group header
            HStack {
                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                
                Circle()
                    .fill(Color.green)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Text("\(groupNumber + 1)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                    )
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Velocity Layer \(groupNumber + 1)")
                        .font(.headline)
                    Text("\(markers.count) sample\(markers.count == 1 ? "" : "s") (round-robins)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            
            // Expanded sample list
            if isExpanded {
                VStack(spacing: 4) {
                    ForEach(Array(markers.enumerated()), id: \.element.id) { index, marker in
                        HStack {
                            Text("\(index + 1).")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 20)
                            
                            Text(markerName(for: marker))
                                .font(.caption)
                                .lineLimit(1)
                            
                            Spacer()
                            
                            Button(action: { onPlayMarker(marker) }) {
                                Image(systemName: playingMarkers.contains(marker.id) ? "stop.circle.fill" : "play.circle")
                                    .foregroundColor(playingMarkers.contains(marker.id) ? .accentColor : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .background(Color.gray.opacity(0.02))
                        .cornerRadius(4)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }
    
    private func markerName(for marker: Marker) -> String {
        // Find marker index in sorted list
        let sortedMarkers = audioViewModel.markers.sorted { $0.samplePosition < $1.samplePosition }
        if let index = sortedMarkers.firstIndex(where: { $0.id == marker.id }) {
            return "Region \(index + 1)"
        }
        
        return "Unknown"
    }
}
