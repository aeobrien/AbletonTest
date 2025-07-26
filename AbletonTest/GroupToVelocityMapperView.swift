import SwiftUI

// MARK: - Group to Velocity Mapper View

struct GroupToVelocityMapperView: View {
    @EnvironmentObject var samplerViewModel: SamplerViewModel
    @ObservedObject var audioViewModel: EnhancedAudioViewModel
    @Environment(\.dismiss) var dismiss
    
    @State private var selectedGroups: Set<Int> = []
    @State private var targetKeyId: Int?
    @State private var splitMode: VelocitySplitMode = .separate
    
    // Group the markers by their group ID
    var markerGroups: [TransientGroup] {
        let groupedMarkers = Dictionary(grouping: audioViewModel.markers.filter { $0.group != nil }, by: { $0.group! })
        return groupedMarkers.map { TransientGroup(id: $0.key, markers: $0.value) }
            .sorted { $0.id < $1.id }
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            Text("Map Groups to Velocity Layers")
                .font(.title2)
                .bold()
            
            if markerGroups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    
                    Text("No groups found")
                        .font(.headline)
                    
                    Text("Create groups by selecting markers in the waveform view")
                        .foregroundColor(.secondary)
                }
                .padding(40)
            } else {
                // Group selection
                VStack(alignment: .leading, spacing: 10) {
                    Text("Select Groups to Map:")
                        .font(.headline)
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(markerGroups) { group in
                                GroupSelectionRow(
                                    group: group,
                                    isSelected: selectedGroups.contains(group.id),
                                    onToggle: {
                                        if selectedGroups.contains(group.id) {
                                            selectedGroups.remove(group.id)
                                        } else {
                                            selectedGroups.insert(group.id)
                                        }
                                    }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                    .border(Color.gray.opacity(0.3))
                    
                    HStack {
                        Button("Select All") {
                            selectedGroups = Set(markerGroups.map { $0.id })
                        }
                        
                        Button("Clear Selection") {
                            selectedGroups.removeAll()
                        }
                    }
                }
                
                Divider()
                
                // Target key selection
                VStack(alignment: .leading, spacing: 10) {
                    Text("Target Key:")
                        .font(.headline)
                    
                    HStack {
                        if let selectedKey = targetKeyId {
                            Text(noteNameForMIDI(selectedKey))
                                .font(.title3)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.blue.opacity(0.2))
                                .cornerRadius(6)
                        }
                        
                        Menu {
                            ForEach(createNoteOptions(), id: \.0) { note, name in
                                Button(name) {
                                    targetKeyId = note
                                }
                            }
                        } label: {
                            Label(targetKeyId == nil ? "Select Note" : "Change Note", 
                                  systemImage: "piano")
                        }
                        .menuStyle(.borderlessButton)
                    }
                    
                    if targetKeyId == nil {
                        Text("Select a target note from the menu above")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Divider()
                
                // Velocity split mode
                VStack(alignment: .leading, spacing: 10) {
                    Text("Velocity Split Mode:")
                        .font(.headline)
                    
                    Picker("Split Mode", selection: $splitMode) {
                        Text("Separate (No Overlap)").tag(VelocitySplitMode.separate)
                        Text("Crossfade (With Overlap)").tag(VelocitySplitMode.crossfade)
                    }
                    .pickerStyle(RadioGroupPickerStyle())
                }
            }
            
            Spacer()
            
            // Action buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                
                Spacer()
                
                Button("Map to Velocity Layers") {
                    performMapping()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedGroups.isEmpty || targetKeyId == nil)
            }
        }
        .padding()
        .frame(width: 500, height: 600)
    }
    
    private func performMapping() {
        guard let keyId = targetKeyId else { return }
        
        let groupsToMap = markerGroups.filter { selectedGroups.contains($0.id) }
        samplerViewModel.mapTransientGroupsToVelocityLayers(
            groups: groupsToMap,
            toKey: keyId,
            splitMode: splitMode
        )
        
        dismiss()
    }
    
    private func noteNameForMIDI(_ midiNote: Int) -> String {
        let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = (midiNote / 12) - 2
        let noteIndex = midiNote % 12
        return "\(noteNames[noteIndex])\(octave)"
    }
    
    private func createNoteOptions() -> [(Int, String)] {
        var options: [(Int, String)] = []
        let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        
        // Create options for common range C0 to C8
        for octave in -2...8 {
            for (index, noteName) in noteNames.enumerated() {
                let midiNote = (octave + 2) * 12 + index
                if midiNote >= 0 && midiNote <= 127 {
                    let displayName = "\(noteName)\(octave) (MIDI \(midiNote))"
                    options.append((midiNote, displayName))
                }
            }
        }
        
        return options
    }
}

// MARK: - Group Selection Row

struct GroupSelectionRow: View {
    let group: TransientGroup
    let isSelected: Bool
    let onToggle: () -> Void
    
    var body: some View {
        HStack {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            
            VStack(alignment: .leading) {
                Text(group.name)
                    .font(.headline)
                
                Text("\(group.sampleCount) markers")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Preview of marker positions
            HStack(spacing: 2) {
                ForEach(group.markers.prefix(5)) { marker in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.green)
                        .frame(width: 4, height: 20)
                }
                if group.markers.count > 5 {
                    Text("+\(group.markers.count - 5)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(6)
    }
}