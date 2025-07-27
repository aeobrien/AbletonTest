import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Main Content View

struct ContentView: View {
    @StateObject private var audioViewModel = EnhancedAudioViewModel()
    @StateObject private var samplerViewModel = SamplerViewModel()
    @StateObject private var midiManager = MIDIManager()
    
    @State private var showingBatchImport = false
    @State private var showingGroupMapper = false
    @State private var showingExportXML = false
    @State private var batchImportURLs: [URL] = []
    @State private var selectedTab = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // Tab selection
            Picker("View", selection: $selectedTab) {
                Text("Transient Detection").tag(0)
                Text("Keyboard Mapping").tag(1)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding()
            
            if selectedTab == 0 {
                // Transient Detection View
                transientDetectionView
            } else {
                // Keyboard Mapping View
                keyboardMappingView
            }
        }
        .environmentObject(samplerViewModel)
        .environmentObject(audioViewModel)
        .environmentObject(midiManager)
        .onAppear {
            // Link the audio view model to the sampler view model
            samplerViewModel.audioViewModel = audioViewModel
        }
        .sheet(isPresented: $showingBatchImport) {
            BatchImportView(fileURLs: batchImportURLs)
                .environmentObject(samplerViewModel)
        }
        .sheet(isPresented: $showingGroupMapper) {
            GroupToVelocityMapperView(audioViewModel: audioViewModel)
                .environmentObject(samplerViewModel)
        }
        .sheet(isPresented: $showingExportXML) {
            if let xmlContent = generatePreviewXML() {
                ExportXMLView(xmlContent: xmlContent)
            }
        }
    }
    
    // MARK: - Transient Detection View
    
    private var transientDetectionView: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text("Transient Detection & Grouping")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button(action: { audioViewModel.showImporter = true }) {
                    Label("Import WAV", systemImage: "waveform")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            
            // Main waveform
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Waveform")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                }
                .padding(.horizontal)
                
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        // Marker handles above waveform
                        GeometryReader { geometry in
                            if audioViewModel.isInspectingTransients {
                                // In inspection mode, only show current region handles
                                let sortedTransients = Array(audioViewModel.transientMarkers).sorted()
                                if audioViewModel.currentTransientIndex >= 0 && audioViewModel.currentTransientIndex < sortedTransients.count {
                                    let transientPosition = sortedTransients[audioViewModel.currentTransientIndex]
                                    
                                    // Find the marker for this transient
                                    if let markerIndex = audioViewModel.markers.firstIndex(where: { $0.samplePosition == transientPosition }) {
                                        MarkerHandle(
                                            marker: audioViewModel.markers[markerIndex],
                                            markerIndex: markerIndex,
                                            geometry: geometry,
                                            audioViewModel: audioViewModel
                                        )
                                        
                                        // End handle for the current region
                                        RegionEndHandle(
                                            marker: audioViewModel.markers[markerIndex],
                                            markerIndex: markerIndex,
                                            geometry: geometry,
                                            audioViewModel: audioViewModel
                                        )
                                    }
                                }
                            } else {
                                // Normal mode - show all handles
                                ForEach(audioViewModel.markers.indices, id: \.self) { index in
                                    MarkerHandle(
                                        marker: audioViewModel.markers[index],
                                        markerIndex: index,
                                        geometry: geometry,
                                        audioViewModel: audioViewModel
                                    )
                                }
                            }
                        }
                        .frame(height: 12)
                        
                        EnhancedWaveformView(viewModel: audioViewModel)
                            .clipped()
                        
                        // Marker play buttons below waveform
                        GeometryReader { geometry in
                            if audioViewModel.isInspectingTransients {
                                // In inspection mode, only show play button for current region
                                let sortedTransients = Array(audioViewModel.transientMarkers).sorted()
                                if audioViewModel.currentTransientIndex >= 0 && audioViewModel.currentTransientIndex < sortedTransients.count {
                                    let transientPosition = sortedTransients[audioViewModel.currentTransientIndex]
                                    
                                    if let marker = audioViewModel.markers.first(where: { $0.samplePosition == transientPosition }) {
                                        let x = audioViewModel.xPosition(for: marker.samplePosition, in: geometry.size.width)
                                        
                                        if x >= 0 && x <= geometry.size.width {
                                            Button(action: {
                                                audioViewModel.playMarkerRegion(marker: marker)
                                            }) {
                                                Image(systemName: "play.circle.fill")
                                                    .font(.system(size: 16))
                                                    .foregroundColor(.purple)
                                            }
                                            .buttonStyle(.plain)
                                            .position(x: x, y: 6)
                                        }
                                    }
                                }
                            } else {
                                // Normal mode - show all play buttons
                                ForEach(audioViewModel.markers) { marker in
                                    let x = audioViewModel.xPosition(for: marker.samplePosition, in: geometry.size.width)
                                    
                                    // Only show if marker is visible
                                    if x >= 0 && x <= geometry.size.width {
                                        Button(action: {
                                            audioViewModel.playMarkerRegion(marker: marker)
                                        }) {
                                            Image(systemName: "play.circle.fill")
                                                .font(.system(size: 16))
                                                .foregroundColor(marker.group == nil ? .red : .green)
                                        }
                                        .buttonStyle(.plain)
                                        .position(x: x, y: 6)
                                    }
                                }
                            }
                        }
                        .frame(height: 12)
                    }
                }
                .padding(.horizontal)
            }
            
            // Minimap
            MinimapView(viewModel: audioViewModel)
                .padding(.horizontal)
            
            // Transport controls
            HStack {
                Button(action: {
                    audioViewModel.playSelection()
                }) {
                    Image(systemName: audioViewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                .buttonStyle(.bordered)
                .disabled(audioViewModel.sampleBuffer == nil)
                
                Button(action: {
                    audioViewModel.stopPlayback()
                }) {
                    Image(systemName: "stop.fill")
                        .font(.title2)
                }
                .buttonStyle(.bordered)
                .disabled(!audioViewModel.isPlaying)
                
                Spacer()
            }
            .padding(.horizontal)
            
            // Reorganized controls
            VStack(spacing: 0) {
                // Main controls section
                HStack(alignment: .top, spacing: 20) {
                    // View controls group (moved to left)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("VIEW CONTROLS")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fontWeight(.semibold)
                        
                        HStack(spacing: 12) {
                            if audioViewModel.tempSelection != nil {
                                Button(action: {
                                    audioViewModel.zoomToSelection()
                                }) {
                                    Label("Zoom to Selection", systemImage: "viewfinder")
                                        .font(.caption)
                                }
                                
                                Button(action: {
                                    audioViewModel.clearSelection()
                                }) {
                                    Text("Clear Selection")
                                        .font(.caption)
                                }
                                .foregroundColor(.red)
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Zoom")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                HStack {
                                    Slider(value: $audioViewModel.zoomLevel, in: 1...500)
                                        .frame(width: 150)
                                    Text(String(format: "%.0fx", audioViewModel.zoomLevel))
                                        .font(.caption)
                                        .frame(width: 35)
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Y-Scale")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                HStack {
                                    Slider(value: $audioViewModel.yScale, in: 0.01...20.0)
                                        .frame(width: 150)
                                    Text(String(format: "%.1fx", audioViewModel.yScale))
                                        .font(.caption)
                                        .frame(width: 35)
                                }
                            }
                        }
                    }
                    
                    Divider()
                        .frame(height: 100)
                    
                    // Transient controls group (moved to center)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TRANSIENT DETECTION")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fontWeight(.semibold)
                        
                        HStack(spacing: 8) {
                            Button(action: {
                                audioViewModel.detectTransients()
                            }) {
                                Label("Detect", systemImage: "waveform.badge.plus")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(audioViewModel.sampleBuffer == nil)
                            
                            if audioViewModel.hasDetectedTransients && !audioViewModel.isInspectingTransients {
                                Button(action: {
                                    audioViewModel.startTransientInspection()
                                }) {
                                    Label("Inspect", systemImage: "magnifyingglass")
                                        .font(.caption)
                                }
                            }
                            
                            Button(action: {
                                audioViewModel.markers.removeAll()
                                audioViewModel.transientMarkers.removeAll()
                                audioViewModel.hasDetectedTransients = false
                            }) {
                                Text("Clear")
                                    .font(.caption)
                            }
                            .foregroundColor(.red)
                            .disabled(audioViewModel.markers.isEmpty)
                            
                            if audioViewModel.isInspectingTransients {
                                HStack(spacing: 4) {
                                    Divider()
                                        .frame(height: 20)
                                    
                                    Button(action: {
                                        audioViewModel.previousTransient()
                                    }) {
                                        Image(systemName: "chevron.left")
                                    }
                                    
                                    Text("\(audioViewModel.currentTransientIndex + 1)/\(audioViewModel.transientMarkers.count)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    
                                    Button(action: {
                                        audioViewModel.nextTransient()
                                    }) {
                                        Image(systemName: "chevron.right")
                                    }
                                    
                                    Button(action: {
                                        audioViewModel.stopTransientInspection()
                                    }) {
                                        Image(systemName: "xmark.circle")
                                    }
                                    .foregroundColor(.red)
                                }
                            }
                        }
                        
                        // Stacked threshold and offset
                        VStack(alignment: .leading, spacing: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Threshold")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                HStack {
                                    Slider(
                                        value: Binding(
                                            get: { audioViewModel.transientThreshold },
                                            set: { audioViewModel.updateTransientThreshold($0) }
                                        ),
                                        in: 0.001...1.0
                                    )
                                    .frame(width: 150)
                                    Text(String(format: "%.2f", audioViewModel.transientThreshold))
                                        .font(.caption)
                                        .frame(width: 35)
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Offset (ms)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                HStack {
                                    Slider(
                                        value: Binding(
                                            get: { audioViewModel.transientOffsetMs },
                                            set: { newValue in
                                                let oldValue = audioViewModel.transientOffsetMs
                                                audioViewModel.transientOffsetMs = newValue
                                                if audioViewModel.hasDetectedTransients {
                                                    audioViewModel.updateTransientOffsets(oldOffset: oldValue, newOffset: newValue)
                                                }
                                            }
                                        ),
                                        in: -50...50
                                    )
                                    .frame(width: 150)
                                    Text(String(format: "%.1f", audioViewModel.transientOffsetMs))
                                        .font(.caption)
                                        .frame(width: 35)
                                }
                            }
                        }
                    }
                    
                    Divider()
                        .frame(height: 100)
                    
                    // Groups section (new)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("GROUPS")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fontWeight(.semibold)
                        
                        Toggle("Auto-assign groups", isOn: $audioViewModel.autoAssignGroups)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                        
                        Button(action: {
                            showingGroupMapper = true
                        }) {
                            Label("Map Groups to Keys", systemImage: "piano")
                                .font(.caption)
                        }
                        .disabled(audioViewModel.markers.filter { $0.group != nil }.isEmpty)
                    }
                    
                    Spacer()
                }
                .padding()
                .background(Color.gray.opacity(0.05))
                .cornerRadius(8)
                .padding(.horizontal)
            }
            
            
            Spacer()
        }
        .padding(.vertical)
        .fileImporter(
            isPresented: $audioViewModel.showImporter,
            allowedContentTypes: [.wav]
        ) { result in
            if case .success(let url) = result {
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    audioViewModel.importWAV(from: url)
                }
            }
        }
        .popover(isPresented: $audioViewModel.showGroupAssignmentMenu) {
            GroupAssignmentPopover(audioViewModel: audioViewModel)
        }
    }
    
    // MARK: - Keyboard Mapping View
    
    private var keyboardMappingView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Keyboard & Velocity Mapping")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Menu {
                    Button(action: {
                        // Show file picker for batch import
                        let panel = NSOpenPanel()
                        panel.allowsMultipleSelection = true
                        panel.allowedContentTypes = [.wav]
                        panel.begin { response in
                            if response == .OK {
                                batchImportURLs = panel.urls
                                showingBatchImport = true
                            }
                        }
                    }) {
                        Label("Batch Import...", systemImage: "square.and.arrow.down.on.square")
                    }
                    
                    Button(action: {
                        showingGroupMapper = true
                    }) {
                        Label("Map Groups to Velocity Layers...", systemImage: "rectangle.3.group")
                    }
                    .disabled(audioViewModel.markers.filter { $0.group != nil }.isEmpty)
                    
                } label: {
                    Label("Import", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                
                Button(action: {
                    samplerViewModel.saveToADVFile()
                }) {
                    Label("Export ADV", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(samplerViewModel.multiSampleParts.isEmpty)
            }
            .padding()
            
            // Piano keyboard
            PianoKeyboardView(keys: $samplerViewModel.pianoKeys) { keyId in
                samplerViewModel.selectKey(keyId)
            }
            .frame(height: 100)
            .padding(.horizontal)
            
            Divider()
            
            // Velocity layers for selected key
            if let selectedKeyId = samplerViewModel.selectedKeyId {
                ScrollView {
                    VelocityLayerGridView(
                        velocityLayers: $samplerViewModel.velocityLayers,
                        keyId: selectedKeyId
                    )
                }
            } else {
                VStack {
                    Spacer()
                    Text("Select a key to view its velocity layers")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            
            // Status bar
            HStack {
                Text("\(samplerViewModel.multiSampleParts.count) samples loaded")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if samplerViewModel.currentMappingMode == .roundRobin {
                    Label("Round Robin", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                
                Button(action: {
                    showingExportXML = true
                }) {
                    Text("Preview XML")
                        .font(.caption)
                }
                .disabled(samplerViewModel.multiSampleParts.isEmpty)
            }
            .padding()
            .background(Color.gray.opacity(0.05))
        }
        .alert("Error", isPresented: .constant(samplerViewModel.errorAlertMessage != nil)) {
            Button("OK") {
                samplerViewModel.errorAlertMessage = nil
            }
        } message: {
            Text(samplerViewModel.errorAlertMessage ?? "")
        }
        .sheet(isPresented: $samplerViewModel.showingVelocitySplitPrompt) {
            VelocitySplitPromptView(
                pendingDropInfo: samplerViewModel.pendingDropInfo,
                onComplete: { splitMode in
                    if samplerViewModel.pendingDropInfo != nil {
                        // Handle the dropped files with the selected split mode
                        // This would need implementation based on your specific needs
                    }
                    samplerViewModel.showingVelocitySplitPrompt = false
                    samplerViewModel.pendingDropInfo = nil
                }
            )
        }
    }
    
    // MARK: - Helper Methods
    
    private func generatePreviewXML() -> String? {
        guard !samplerViewModel.multiSampleParts.isEmpty else { return nil }
        
        // Generate a preview of the XML (without file operations)
        let projectPath = FileManager.default.temporaryDirectory.path
        return samplerViewModel.generateFullXmlString(projectPath: projectPath)
    }
}

// MARK: - Velocity Split Prompt View

struct VelocitySplitPromptView: View {
    let pendingDropInfo: (midiNote: Int, fileURLs: [URL])?
    let onComplete: (VelocitySplitMode) -> Void
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Text("How should these samples be split across velocities?")
                .font(.headline)
            
            if let info = pendingDropInfo {
                Text("\(info.fileURLs.count) files for note \(info.midiNote)")
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 10) {
                Button(action: {
                    onComplete(.separate)
                    dismiss()
                }) {
                    VStack(alignment: .leading) {
                        Text("Separate Zones")
                            .font(.headline)
                        Text("Each sample gets its own velocity range with no overlap")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    onComplete(.crossfade)
                    dismiss()
                }) {
                    VStack(alignment: .leading) {
                        Text("Crossfade Zones")
                            .font(.headline)
                        Text("Velocity ranges overlap for smooth transitions")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            
            Button("Cancel") {
                dismiss()
            }
            .padding(.top)
        }
        .padding()
        .frame(width: 400)
    }
}

// MARK: - Group Assignment Popover

struct GroupAssignmentPopover: View {
    @ObservedObject var audioViewModel: EnhancedAudioViewModel
    @State private var selectedGroup = 1
    
    var existingGroups: [Int] {
        let groups = audioViewModel.markers.compactMap { $0.group }.sorted()
        return groups.isEmpty ? [1] : Array(1...(groups.max()! + 1))
    }
    
    var selectedMarkerCount: Int {
        guard let range = audioViewModel.pendingGroupAssignment else { return 0 }
        return audioViewModel.markers.filter { range.contains($0.samplePosition) }.count
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Assign \(selectedMarkerCount) marker\(selectedMarkerCount == 1 ? "" : "s") to group:")
                .font(.headline)
            
            Picker("Group", selection: $selectedGroup) {
                ForEach(existingGroups, id: \.self) { group in
                    Text("Group \(group)").tag(group)
                }
            }
            .pickerStyle(MenuPickerStyle())
            .frame(width: 150)
            
            HStack(spacing: 20) {
                Button("Assign to Group") {
                    audioViewModel.assignToGroup(selectedGroup)
                }
                .buttonStyle(.borderedProminent)
                
                Button("Assign Incrementally") {
                    audioViewModel.assignIncrementally()
                }
                .disabled(selectedMarkerCount < 2)
                
                Button("Unassign") {
                    audioViewModel.unassignFromGroups()
                }
                .foregroundColor(.red)
                
                Button("Cancel") {
                    audioViewModel.showGroupAssignmentMenu = false
                    audioViewModel.pendingGroupAssignment = nil
                    audioViewModel.tempSelection = nil
                }
            }
            
            if selectedMarkerCount > 1 {
                Text("Incremental assignment will assign markers to groups 1, 2, 3...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 400)
    }
}

// MARK: - Marker Handle View

struct MarkerHandle: View {
    let marker: Marker
    let markerIndex: Int
    let geometry: GeometryProxy
    @ObservedObject var audioViewModel: EnhancedAudioViewModel
    
    @State private var isDragging = false
    @State private var dragStartPosition: CGFloat = 0
    @State private var dragStartSamplePosition: Int = 0
    
    var body: some View {
        let x = audioViewModel.xPosition(for: marker.samplePosition, in: geometry.size.width)
        
        // Only show if marker is visible
        if x >= 0 && x <= geometry.size.width {
            Circle()
                .fill(marker.group == nil ? Color.red : Color.green)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .stroke(Color.white, lineWidth: 1)
                )
                .position(x: x, y: 6)
                .onTapGesture(count: 2) {
                    // Double-click to delete marker
                    audioViewModel.deleteMarker(at: markerIndex)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // Store initial position on first drag
                            if !isDragging {
                                isDragging = true
                                dragStartPosition = x
                                dragStartSamplePosition = marker.samplePosition
                            }
                            // Calculate new position based on drag start
                            let newX = dragStartPosition + value.translation.width
                            audioViewModel.moveMarker(at: markerIndex, toX: newX, width: geometry.size.width)
                        }
                        .onEnded { _ in
                            // Reset for next drag
                            isDragging = false
                            dragStartPosition = 0
                            dragStartSamplePosition = 0
                        }
                )
        }
    }
}

// MARK: - Region End Handle View

struct RegionEndHandle: View {
    let marker: Marker
    let markerIndex: Int
    let geometry: GeometryProxy
    @ObservedObject var audioViewModel: EnhancedAudioViewModel
    
    @State private var isDragging = false
    @State private var dragStartPosition: CGFloat = 0
    @State private var dragStartEndPosition: Int = 0
    
    private var endPosition: Int {
        // Calculate end position
        let sortedMarkers = audioViewModel.markers.sorted { $0.samplePosition < $1.samplePosition }
        let currentIndex = sortedMarkers.firstIndex { $0.id == marker.id } ?? markerIndex
        
        if let customEnd = marker.customEndPosition {
            return customEnd
        } else if currentIndex < sortedMarkers.count - 1 {
            return sortedMarkers[currentIndex + 1].samplePosition
        } else {
            return audioViewModel.totalSamples
        }
    }
    
    var body: some View {
        let x = audioViewModel.xPosition(for: endPosition, in: geometry.size.width)
        
        // Only show if end marker is visible
        if x >= 0 && x <= geometry.size.width {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.purple.opacity(0.6))
                .frame(width: 8, height: 12)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.white, lineWidth: 1)
                )
                .position(x: x, y: 6)
                .onTapGesture(count: 2) {
                    // Double-click to reset to auto position
                    audioViewModel.resetMarkerEndPosition(at: markerIndex)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // Store initial position on first drag
                            if !isDragging {
                                isDragging = true
                                dragStartPosition = x
                                dragStartEndPosition = endPosition
                            }
                            // Calculate new position based on drag start
                            let newX = dragStartPosition + value.translation.width
                            audioViewModel.moveMarkerEndPosition(at: markerIndex, toX: newX, width: geometry.size.width)
                        }
                        .onEnded { _ in
                            // Reset for next drag
                            isDragging = false
                            dragStartPosition = 0
                            dragStartEndPosition = 0
                        }
                )
        }
    }
}

// MARK: - App Entry Point

@main
struct AbletonTestApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.automatic)
    }
}