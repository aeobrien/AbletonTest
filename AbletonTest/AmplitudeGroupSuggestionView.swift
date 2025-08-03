import SwiftUI
import AVFoundation

struct AmplitudeGroupSuggestionView: View {
    @ObservedObject var audioViewModel: EnhancedAudioViewModel
    @Environment(\.dismiss) var dismiss
    
    @State private var numberOfGroups: Int = 3
    @State private var letSoftwareGuess = false
    @State private var suggestedGrouping: [Int: [Marker]] = [:]
    @State private var showingSuggestions = false
    @State private var isAnalyzing = false
    @State private var previewingGroup: Int? = nil
    @State private var playingAllInGroup: Int? = nil
    @State private var currentPlayingMarkerIndex: Int = 0
    @State private var groupPlaybackTimer: Timer? = nil
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Amplitude-Based Group Assignment")
                .font(.title2)
                .fontWeight(.semibold)
            
            if !showingSuggestions {
                // Initial configuration
                VStack(spacing: 20) {
                    Text("How would you like to group regions by amplitude?")
                        .font(.headline)
                    
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Button(action: {
                                letSoftwareGuess = false
                            }) {
                                HStack {
                                    Image(systemName: letSoftwareGuess ? "circle" : "checkmark.circle.fill")
                                    Text("Specify number of groups:")
                                }
                            }
                            .buttonStyle(.plain)
                            
                            Stepper(value: $numberOfGroups, in: 2...10) {
                                Text("\(numberOfGroups) groups")
                            }
                            .disabled(letSoftwareGuess)
                        }
                        
                        Button(action: {
                            letSoftwareGuess = true
                        }) {
                            HStack {
                                Image(systemName: letSoftwareGuess ? "checkmark.circle.fill" : "circle")
                                Text("Let software determine optimal grouping")
                            }
                        }
                        .buttonStyle(.plain)
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
                            analyzeAmplitudes()
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
                                    isPlaying: previewingGroup == groupNum,
                                    isPlayingAll: playingAllInGroup == groupNum,
                                    onPreview: {
                                        toggleGroupPreview(groupNum)
                                    },
                                    onAuditionAll: {
                                        toggleGroupAudition(groupNum)
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
            if playingAllInGroup != nil {
                audioViewModel.stopPlayback()
                groupPlaybackTimer?.invalidate()
                playingAllInGroup = nil
            }
            if previewingGroup != nil {
                audioViewModel.stopPlayback()
                previewingGroup = nil
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
            
            // Determine grouping
            var grouping: [Int: [Marker]] = [:]
            
            if letSoftwareGuess {
                // Use k-means clustering or similar to determine optimal groups
                let optimalGroups = determineOptimalGroups(from: regionAmplitudes)
                grouping = optimalGroups
            } else {
                // Distribute into specified number of groups
                let markersPerGroup = regionAmplitudes.count / numberOfGroups
                let remainder = regionAmplitudes.count % numberOfGroups
                
                var currentIndex = 0
                for group in 1...numberOfGroups {
                    let groupSize = markersPerGroup + (group <= remainder ? 1 : 0)
                    let groupMarkers = regionAmplitudes[currentIndex..<(currentIndex + groupSize)].map { $0.marker }
                    grouping[group] = groupMarkers
                    currentIndex += groupSize
                }
            }
            
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
    
    private func toggleGroupPreview(_ groupNum: Int) {
        if previewingGroup == groupNum {
            audioViewModel.stopPlayback()
            previewingGroup = nil
        } else {
            previewingGroup = groupNum
            playGroupRegions(groupNum)
        }
    }
    
    private func playGroupRegions(_ groupNum: Int) {
        guard let markers = suggestedGrouping[groupNum], !markers.isEmpty else { return }
        
        // Play the first region in the group as a sample
        let firstMarker = markers[0]
        let sortedMarkers = audioViewModel.markers.sorted { $0.samplePosition < $1.samplePosition }
        
        if let index = sortedMarkers.firstIndex(where: { $0.id == firstMarker.id }) {
            // Create a temporary selection for the region
            let startPos = firstMarker.samplePosition
            let endPos: Int
            
            if let customEnd = firstMarker.customEndPosition {
                endPos = customEnd
            } else if index < sortedMarkers.count - 1 {
                endPos = sortedMarkers[index + 1].samplePosition
            } else {
                endPos = audioViewModel.zoneStartOffset + audioViewModel.zoneTotalSamples
            }
            
            audioViewModel.tempSelection = startPos...endPos
            audioViewModel.playSelection()
            
            // Clear selection after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                audioViewModel.tempSelection = nil
            }
        }
    }
    
    private func toggleGroupAudition(_ groupNum: Int) {
        // Stop any current playback
        if playingAllInGroup != nil {
            audioViewModel.stopPlayback()
            groupPlaybackTimer?.invalidate()
            playingAllInGroup = nil
            currentPlayingMarkerIndex = 0
        } else if previewingGroup != nil {
            audioViewModel.stopPlayback()
            previewingGroup = nil
        }
        
        // Start group audition if this is a new group
        if playingAllInGroup != groupNum {
            playingAllInGroup = groupNum
            currentPlayingMarkerIndex = 0
            playNextMarkerInGroup()
        }
    }
    
    private func playNextMarkerInGroup() {
        guard let groupNum = playingAllInGroup,
              let markers = suggestedGrouping[groupNum],
              currentPlayingMarkerIndex < markers.count else {
            // Finished playing all markers in group
            playingAllInGroup = nil
            currentPlayingMarkerIndex = 0
            return
        }
        
        let marker = markers[currentPlayingMarkerIndex]
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
            
            // Play this region
            audioViewModel.tempSelection = startPos...endPos
            audioViewModel.playSelection()
            
            // Calculate duration for this region
            let duration = Double(endPos - startPos) / audioViewModel.sampleRate
            
            // Schedule next marker playback
            groupPlaybackTimer = Timer.scheduledTimer(withTimeInterval: duration + 0.2, repeats: false) { _ in
                self.currentPlayingMarkerIndex += 1
                self.playNextMarkerInGroup()
            }
        }
    }
    
    private func applyGrouping() {
        // Apply the suggested grouping to the markers
        for (groupNum, markers) in suggestedGrouping {
            for marker in markers {
                if let index = audioViewModel.markers.firstIndex(where: { $0.id == marker.id }) {
                    audioViewModel.markers[index].group = groupNum
                }
            }
        }
    }
}

struct GroupSuggestionRow: View {
    let groupNumber: Int
    let markers: [Marker]
    let isPlaying: Bool
    let isPlayingAll: Bool
    let onPreview: () -> Void
    let onAuditionAll: () -> Void
    
    var body: some View {
        HStack {
            Circle()
                .fill(Color.green)
                .frame(width: 20, height: 20)
                .overlay(
                    Text("\(groupNumber)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                )
            
            VStack(alignment: .leading) {
                Text("Group \(groupNumber)")
                    .font(.headline)
                Text("\(markers.count) regions")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: onAuditionAll) {
                Image(systemName: isPlayingAll ? "stop.fill" : "speaker.wave.3.fill")
            }
            .buttonStyle(.plain)
            .help("Audition all regions in this group")
            
            Button(action: onPreview) {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            .help("Play first region as sample")
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }
}