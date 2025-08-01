import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Main Content View

struct ContentView: View {
    @StateObject private var audioViewModel = EnhancedAudioViewModel()
    @StateObject private var samplerViewModel = SamplerViewModel()
    @StateObject private var midiManager = MIDIManager()
    
    @State private var showingBatchImport = false
    @State private var showingExportXML = false
    @State private var batchImportURLs: [URL] = []
    @State private var selectedTab = 0
    
    // Velocity mapping states
    @State private var selectedGroups: Set<Int> = []
    @State private var targetKeyId: Int?
    @State private var splitMode: VelocitySplitMode = .separate
    @State private var mappingMode: MappingMode = .standard
    @State private var isPitchedMode = false
    @State private var keyRangeMin = 0
    @State private var keyRangeMax = 127
    @State private var rootKey = 60
    @State private var selectedGroupForAssignment = 1
    
    // Computed properties
    var hasGroups: Bool {
        !audioViewModel.markerGroups.isEmpty
    }
    
    var mappingButtonText: String {
        switch mappingMode {
        case .standard:
            return "Map to Single Key"
        case .roundRobin:
            return "Map to Pitched Range"
        case .multipleKeys:
            return "Map to Multiple Keys"
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Tab selection
            HStack {
                Picker("", selection: $selectedTab) {
                    Label("Transient Detection", systemImage: "waveform.badge.magnifyingglass")
                        .tag(0)
                    Label("Keyboard Mapping", systemImage: "piano")
                        .tag(1)
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 400)
                
                Spacer()
                
                Button(action: { audioViewModel.showImporter = true }) {
                    Label("Import WAV", systemImage: "waveform")
                        .font(.system(size: 13))
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color.gray.opacity(0.05))
            
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
        .background(
            // Hidden buttons for keyboard shortcuts
            Group {
                // Toggle inspection mode with 'I'
                Button("") {
                    if audioViewModel.isInspectingTransients {
                        audioViewModel.stopTransientInspection()
                    } else if !audioViewModel.markers.isEmpty {
                        audioViewModel.startTransientInspection()
                    }
                }
                .keyboardShortcut("i", modifiers: [])
                .hidden()
                
                // Detect transients with 'D'
                Button("") {
                    if audioViewModel.sampleBuffer != nil {
                        audioViewModel.detectTransients()
                    }
                }
                .keyboardShortcut("d", modifiers: [])
                .hidden()
                
                // Navigation shortcuts
                Button("") {
                    if audioViewModel.isInspectingTransients {
                        audioViewModel.previousTransient()
                    } else {
                        audioViewModel.scroll(by: -0.05)
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .hidden()
                
                Button("") {
                    if audioViewModel.isInspectingTransients {
                        audioViewModel.nextTransient()
                    } else {
                        audioViewModel.scroll(by: 0.05)
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .hidden()
                
                // Zoom shortcuts
                Button("") {
                    audioViewModel.zoom(by: 1.2, at: 0.5, in: 1.0)
                }
                .keyboardShortcut(.upArrow, modifiers: [])
                .hidden()
                
                Button("") {
                    audioViewModel.zoom(by: 0.8, at: 0.5, in: 1.0)
                }
                .keyboardShortcut(.downArrow, modifiers: [])
                .hidden()
                
                // Delete transients in selection
                Button("") {
                    if let selection = audioViewModel.tempSelection ?? audioViewModel.pendingGroupAssignment {
                        audioViewModel.deleteTransientsInRange(selection)
                    }
                }
                .keyboardShortcut(.delete, modifiers: [])
                .hidden()
            }
        )
        .sheet(isPresented: $showingBatchImport) {
            BatchImportView(fileURLs: batchImportURLs)
                .environmentObject(samplerViewModel)
        }
        .sheet(isPresented: $showingExportXML) {
            if let xmlContent = generatePreviewXML() {
                ExportXMLView(xmlContent: xmlContent)
            }
        }
    }

    
    // MARK: - Transient Detection View
    
    @ViewBuilder
    private var inspectionModeBanner: some View {
        if audioViewModel.isInspectingTransients {
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.title2)
                        .foregroundColor(.purple)
                    
                    Text("INSPECTION MODE")
                        .font(.headline)
                        .foregroundColor(.purple)
                    
                    Spacer()
                    
                    // Auto features checkboxes
                    HStack(spacing: 16) {
                        Toggle("Auto Advance", isOn: $audioViewModel.autoAdvance)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                        
                        Toggle("Auto Audition", isOn: $audioViewModel.autoAudition)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                        
                        if audioViewModel.autoAudition {
                            HStack(spacing: 4) {
                                Text("Loop:")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Slider(value: $audioViewModel.auditionLoopDuration, in: 0.2...1.0)
                                    .frame(width: 80)
                                Text(String(format: "%.1fs", audioViewModel.auditionLoopDuration))
                                    .font(.caption2)
                                    .frame(width: 30)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    // Navigation controls
                    HStack(spacing: 16) {
                        Button(action: {
                            audioViewModel.previousTransient()
                        }) {
                            Image(systemName: "chevron.left")
                        }
                        
                        Text("\(audioViewModel.currentTransientIndex + 1) / \(audioViewModel.markers.count)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.primary)
                        
                        Button(action: {
                            audioViewModel.nextTransient()
                        }) {
                            Image(systemName: "chevron.right")
                        }
                        
                        Divider()
                            .frame(height: 20)
                        
                        // Merge buttons
                        Button(action: {
                            audioViewModel.mergeWithPreviousRegion()
                        }) {
                            Label("Merge Prev", systemImage: "arrow.merge")
                        }
                        .disabled(audioViewModel.currentTransientIndex <= 0)
                        
                        Button(action: {
                            audioViewModel.mergeWithNextRegion()
                        }) {
                            Label("Merge Next", systemImage: "arrow.merge")
                        }
                        .disabled(audioViewModel.currentTransientIndex >= audioViewModel.markers.count - 1)
                        
                        Divider()
                            .frame(height: 20)
                        
                        Button(action: {
                            audioViewModel.stopTransientInspection()
                        }) {
                            Label("Exit Inspection", systemImage: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
                .background(Color.purple.opacity(0.1))
                .cornerRadius(10)
            }
            .padding(.horizontal)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
    
    @ViewBuilder
    private var waveformControls: some View {
        HStack(spacing: 16) {
            // Show transient markers checkbox
            Toggle("Show Transient Markers", isOn: $audioViewModel.showTransientMarkers)
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(audioViewModel.markers.isEmpty)
                .opacity(audioViewModel.markers.isEmpty ? 0.5 : 1.0)
            
            // Show region highlights checkbox
            Toggle("Show Region Highlights", isOn: $audioViewModel.showRegionHighlights)
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(audioViewModel.markers.isEmpty)
                .opacity(audioViewModel.markers.isEmpty ? 0.5 : 1.0)
            
            Spacer()
            
            // Transport buttons in the center
            HStack(spacing: 20) {
                Button(action: {
                    audioViewModel.playSelection()
                }) {
                    Image(systemName: audioViewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                }
                .buttonStyle(.plain)
                .disabled(audioViewModel.sampleBuffer == nil)
                
                Button(action: {
                    audioViewModel.stopPlayback()
                }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 36))
                }
                .buttonStyle(.plain)
                .disabled(!audioViewModel.isPlaying)
            }
            
            Spacer()
            
            if audioViewModel.tempSelection != nil {
                Button(action: {
                    audioViewModel.clearSelection()
                }) {
                    Text("Clear Selection")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
                
                Button(action: {
                    audioViewModel.zoomToSelection()
                }) {
                    Label("Zoom to Selection", systemImage: "viewfinder")
                        .font(.caption)
                }
            }
            
            // Zoom controls
            HStack(spacing: 20) {
                // Zoom X control
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zoom X")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    HStack {
                        Slider(
                            value: Binding(
                                get: { audioViewModel.zoomLevel },
                                set: { newZoom in
                                    audioViewModel.zoom(by: newZoom / audioViewModel.zoomLevel, at: 0.5, in: 1.0)
                                }
                            ),
                            in: 1...500
                        )
                        .frame(width: 120)
                        Text(String(format: "%.0fx", audioViewModel.zoomLevel))
                            .font(.caption)
                            .frame(width: 35)
                    }
                }
                
                // Zoom Y control
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zoom Y")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    HStack {
                        Slider(value: $audioViewModel.yScale, in: 0.01...20.0)
                            .frame(width: 120)
                        Text(String(format: "%.1fx", audioViewModel.yScale))
                            .font(.caption)
                            .frame(width: 35)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private var mainWaveformSection: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    // Marker handles above waveform
                    GeometryReader { geometry in
                        if audioViewModel.isInspectingTransients {
                            // In inspection mode, only show current and next marker handles
                            let sortedMarkers = audioViewModel.markers.sorted { $0.samplePosition < $1.samplePosition }
                            let currentIndex = audioViewModel.currentTransientIndex
                            
                            if currentIndex < sortedMarkers.count {
                                // Current marker handle
                                if let currentMarkerIndex = audioViewModel.markers.firstIndex(where: { $0.id == sortedMarkers[currentIndex].id }) {
                                    MarkerHandle(
                                        marker: audioViewModel.markers[currentMarkerIndex],
                                        markerIndex: currentMarkerIndex,
                                        geometry: geometry,
                                        audioViewModel: audioViewModel
                                    )
                                    
                                    // Next marker handle (grey)
                                    if currentIndex + 1 < sortedMarkers.count {
                                        if let nextMarkerIndex = audioViewModel.markers.firstIndex(where: { $0.id == sortedMarkers[currentIndex + 1].id }) {
                                            MarkerHandle(
                                                marker: audioViewModel.markers[nextMarkerIndex],
                                                markerIndex: nextMarkerIndex,
                                                geometry: geometry,
                                                audioViewModel: audioViewModel,
                                                isGrey: true
                                            )
                                        }
                                    }
                                }
                            }
                        } else if audioViewModel.showTransientMarkers {
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
                        .overlay(
                            Group {
                                if audioViewModel.isDetectingTransients {
                                    ZStack {
                                        // Semi-transparent overlay
                                        Color.black.opacity(0.3)
                                        
                                        // Loading indicator
                                        VStack(spacing: 16) {
                                            ProgressView()
                                                .progressViewStyle(CircularProgressViewStyle())
                                                .scaleEffect(1.5)
                                                .tint(.white)
                                            
                                            Text("Detecting Transients...")
                                                .font(.headline)
                                                .foregroundColor(.white)
                                        }
                                        .padding(24)
                                        .background(Color.black.opacity(0.7))
                                        .cornerRadius(12)
                                    }
                                    .transition(.opacity)
                                }
                            }
                        )
                        .animation(.easeInOut(duration: 0.3), value: audioViewModel.isDetectingTransients)
                    
                    // Marker play buttons and end handles below waveform
                    GeometryReader { geometry in
                        if audioViewModel.isInspectingTransients {
                            // In inspection mode, only show play button for current marker
                            let sortedMarkers = audioViewModel.markers.sorted { $0.samplePosition < $1.samplePosition }
                            let currentIndex = audioViewModel.currentTransientIndex
                            
                            if currentIndex < sortedMarkers.count {
                                let currentMarker = sortedMarkers[currentIndex]
                                let x = audioViewModel.xPosition(for: currentMarker.samplePosition, in: geometry.size.width)
                                
                                if x >= 0 && x <= geometry.size.width {
                                    Button(action: {
                                        audioViewModel.playMarkerRegion(marker: currentMarker)
                                    }) {
                                        Image(systemName: "play.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundColor(.purple)
                                    }
                                    .buttonStyle(.plain)
                                    .position(x: x, y: 6)
                                }
                                
                                // Show end handle as a square for the current marker
                                if let currentMarkerIndex = audioViewModel.markers.firstIndex(where: { $0.id == currentMarker.id }) {
                                    RegionEndHandle(
                                        marker: audioViewModel.markers[currentMarkerIndex],
                                        markerIndex: currentMarkerIndex,
                                        geometry: geometry,
                                        audioViewModel: audioViewModel
                                    )
                                }
                            }
                        } else if audioViewModel.showTransientMarkers {
                            // Normal mode - show all play buttons
                            ForEach(audioViewModel.markers) { marker in
                                let x = audioViewModel.xPosition(for: marker.samplePosition, in: geometry.size.width)
                                
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
        }
        .padding(.horizontal)
    }
    
    @ViewBuilder 
    private var controlsSection: some View {
        VStack(spacing: 0) {
            // Main controls section
            HStack(alignment: .top, spacing: 30) {
                
                // Transient controls group
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        
                        // Algorithm selection at the top
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Algorithm")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Picker("", selection: $audioViewModel.selectedDetectionAlgorithm) {
                                ForEach(TransientDetectionAlgorithm.allCases, id: \.self) { algorithm in
                                    Text(algorithm.displayName).tag(algorithm)
                                }
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 200)
                        }
                        
                        // Threshold slider
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
                                    in: 0.001...2.0
                                )
                                .frame(width: 250)
                                Text(String(format: "%.2f", audioViewModel.transientThreshold))
                                    .font(.caption)
                                    .frame(width: 35)
                            }
                        }
                        
                        // Offset slider
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
                                .frame(width: 250)
                                Text(String(format: "%.1f", audioViewModel.transientOffsetMs))
                                    .font(.caption)
                                    .frame(width: 35)
                            }
                        }
                        
                        // Buttons row
                        HStack(spacing: 12) {
                            Button(action: {
                                print("Detect button pressed")
                                audioViewModel.detectTransients()
                            }) {
                                HStack(spacing: 4) {
                                    if audioViewModel.isDetectingTransients {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle())
                                            .scaleEffect(0.7)
                                    } else {
                                        Image(systemName: "waveform.badge.plus")
                                    }
                                    Text("Detect")
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(audioViewModel.sampleBuffer == nil || audioViewModel.isDetectingTransients)
                            
                            if !audioViewModel.markers.isEmpty && !audioViewModel.isInspectingTransients {
                                Button(action: {
                                    audioViewModel.startTransientInspection()
                                }) {
                                    Label("Inspect Regions", systemImage: "magnifyingglass")
                                        .font(.caption)
                                }
                            }
                            
                            Button(action: {
                                audioViewModel.markers.removeAll()
                                audioViewModel.transientMarkers.removeAll()
                                audioViewModel.hasDetectedTransients = false
                            }) {
                                Text("Clear All")
                                    .font(.caption)
                            }
                            .foregroundColor(.red)
                            .disabled(audioViewModel.markers.isEmpty)
                        }
                        
                        Spacer(minLength: 0)
                    }
                } label: {
                    Label("Transient Detection", systemImage: "waveform.badge.plus")
                        .font(.caption)
                }
                .frame(minWidth: 400)
                .frame(minHeight: 180)
                .disabled(audioViewModel.isInspectingTransients)
                .opacity(audioViewModel.isInspectingTransients ? 0.5 : 1.0)
                
                // Groups section
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        
                        Toggle("Auto-assign groups", isOn: $audioViewModel.autoAssignGroups)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                        
                        Divider()
                        
                        // Group assignment controls
                        VStack(alignment: .leading, spacing: 12) {
                            let range = audioViewModel.pendingGroupAssignment ?? audioViewModel.tempSelection
                            let selectedMarkerCount = range != nil ? audioViewModel.markers.filter { range!.contains($0.samplePosition) }.count : 0
                            let hasSelection = range != nil && selectedMarkerCount > 0
                            
                            Text(hasSelection ? "\(selectedMarkerCount) marker\(selectedMarkerCount == 1 ? "" : "s") selected" : "No markers selected")
                                .font(.caption)
                                .foregroundColor(hasSelection ? .primary : .secondary)
                            
                            // Group picker
                            HStack {
                                Text("Group:")
                                    .font(.caption)
                                    .foregroundColor(hasSelection ? .primary : .secondary)
                                
                                Picker("", selection: $selectedGroupForAssignment) {
                                    ForEach(1...10, id: \.self) { group in
                                        Text("Group \(group)").tag(group)
                                    }
                                }
                                .pickerStyle(MenuPickerStyle())
                                .frame(width: 100)
                                .disabled(!hasSelection)
                                .onAppear {
                                    selectedGroupForAssignment = (audioViewModel.markers.compactMap { $0.group }.max() ?? 0) + 1
                                }
                                
                                Spacer()
                                
                                Button(action: {
                                    audioViewModel.assignToGroup(selectedGroupForAssignment)
                                }) {
                                    Text("Assign")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!hasSelection)
                            }
                            
                            // Sequential button
                            Button(action: {
                                audioViewModel.assignIncrementally()
                            }) {
                                Label("Assign Sequentially", systemImage: "number")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .help("Assign incrementally (1, 2, 3...)")
                            .disabled(!hasSelection || selectedMarkerCount < 2)
                            
                            // Unassign button
                            Button(action: {
                                audioViewModel.unassignFromGroups()
                            }) {
                                Label("Unassign Groups", systemImage: "minus.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!hasSelection)
                            
                            if hasSelection {
                                Button(action: {
                                    audioViewModel.clearSelection()
                                }) {
                                    Label("Clear Selection", systemImage: "xmark.circle")
                                        .font(.caption)
                                }
                                .foregroundColor(.secondary)
                            }
                        }
                        .opacity(audioViewModel.pendingGroupAssignment != nil || audioViewModel.tempSelection != nil ? 1.0 : 0.6)
                        
                        Spacer(minLength: 0)
                    }
                } label: {
                    Label("Groups", systemImage: "rectangle.3.group")
                        .font(.caption)
                }
                .frame(width: 340)
                .frame(minHeight: 180)
                .disabled(audioViewModel.isInspectingTransients)
                .opacity(audioViewModel.isInspectingTransients ? 0.5 : 1.0)
                
                // Mapping section (always visible, disabled when no groups)
                mappingSection
                
                Spacer()
            }
            .padding()
            .background(Color.gray.opacity(0.05))
            .cornerRadius(8)
            .padding(.horizontal)
        }
    }
    
    private var transientDetectionView: some View {
        VStack(spacing: 16) {
            // Inspection Mode Banner
            inspectionModeBanner
            
            // Header
            HStack {
                Text("Transient Detection & Grouping")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
            }
            .padding(.horizontal)
            
            // Combined transport and view controls above waveform
            waveformControls
            
            // Main waveform
            mainWaveformSection
            
            // Minimap
            VStack(spacing: 0) {
                MinimapView(viewModel: audioViewModel)
                    .frame(height: 60)
                    .background(Color.gray.opacity(0.05))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            // Controls section
            controlsSection
            
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
            .alert("Region Length Outliers Detected", isPresented: $audioViewModel.showOutlierAlert) {
                Button("Trim to Match") {
                    audioViewModel.confirmOutlierTrimming()
                }
                Button("Keep Original Lengths", role: .cancel) {
                    audioViewModel.cancelOutlierTrimming()
                }
            } message: {
                if let info = audioViewModel.pendingOutlierInfo {
                    let outlierCount = info.outlierInfo.outlierMarkerIDs.count
                    let normalLengthSeconds = Double(info.outlierInfo.suggestedTrimLength) / 44100.0
                    Text("\(outlierCount) region\(outlierCount == 1 ? " is" : "s are") significantly longer than the others. The typical regions are \(String(format: "%.1f", normalLengthSeconds)) seconds or shorter. Would you like to automatically trim the longer regions to match?")
                }
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
                                self.batchImportURLs = panel.urls
                                self.showingBatchImport = true
                            }
                        }
                    }) {
                        Label("Batch Import...", systemImage: "square.and.arrow.down.on.square")
                    }
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
        .alert("Error",
               isPresented: Binding(
                   get: { samplerViewModel.errorAlertMessage != nil },
                   set: { if !$0 { samplerViewModel.errorAlertMessage = nil } }
               )
        ) {
            Button("OK") { samplerViewModel.errorAlertMessage = nil }
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
    
    // MARK: - Velocity Mapping Section
    
    private var mappingSection: some View {
        let hasGroups = !audioViewModel.markers.filter({ $0.group != nil }).isEmpty
        
        return GroupBox {
            HStack(alignment: .top, spacing: 20) {
                // Column 1 - Group selection
                VStack(alignment: .leading, spacing: 12) {
                    // Group selection
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Select Groups to Map:")
                            .font(.caption)
                            .bold()
                        
                        let markerGroups = audioViewModel.markerGroups
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(markerGroups) { group in
                                    HStack {
                                        Toggle("", isOn: Binding(
                                            get: { selectedGroups.contains(group.id) },
                                            set: { isSelected in
                                                if isSelected {
                                                    selectedGroups.insert(group.id)
                                                } else {
                                                    selectedGroups.remove(group.id)
                                                }
                                            }
                                        ))
                                        .toggleStyle(.checkbox)
                                        
                                        Text("Group \(group.id)")
                                            .font(.caption)
                                        
                                        Text("(\(group.markers.count) markers)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        
                                        Spacer()
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 100)
                        .frame(width: 200)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                        
                        HStack {
                            Button("Select All") {
                                selectedGroups = Set(markerGroups.map { $0.id })
                            }
                            .font(.caption2)
                            
                            Button("Clear") {
                                selectedGroups.removeAll()
                            }
                            .font(.caption2)
                        }
                    }
                    
                }
                
                Divider()
                    .frame(height: 180)
                
                // Column 2 - Mapping settings
                VStack(alignment: .leading, spacing: 12) {
                    // Mapping mode selection
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mapping Mode:")
                            .font(.caption)
                            .bold()
                        
                        Picker("", selection: $mappingMode) {
                            Text("Single Key").tag(MappingMode.standard)
                            Text("Pitched Range").tag(MappingMode.roundRobin)
                            Text("Multi Key").tag(MappingMode.multipleKeys)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 200)
                        .onChange(of: mappingMode) { newMode in
                            // Update isPitchedMode based on mapping mode
                            isPitchedMode = (newMode == .roundRobin)
                        }
                    }
                    
                    // Target key selection
                    if mappingMode != .roundRobin {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mappingMode == .multipleKeys ? "Starting Key:" : "Target Key:")
                                .font(.caption)
                                .bold()
                            
                            HStack {
                                if let selectedKey = targetKeyId {
                                    Text(noteNameForMIDI(selectedKey))
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.2))
                                        .cornerRadius(4)
                                }
                                
                                Picker(targetKeyId == nil ? "Select Note" : "Change Note", selection: $targetKeyId) {
                                    Text("None").tag(nil as Int?)
                                    ForEach(0...127, id: \.self) { note in
                                        Text(noteNameForMIDI(note)).tag(note as Int?)
                                    }
                                }
                                .pickerStyle(MenuPickerStyle())
                                .frame(width: 120)
                            }
                        }
                    } else {
                        // Pitched range controls
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pitched Range:")
                                .font(.caption)
                                .bold()
                            
                            HStack {
                                Text("Root:")
                                    .font(.caption)
                                    .frame(width: 40)
                                Picker("", selection: $rootKey) {
                                    ForEach(0...127, id: \.self) { note in
                                        Text(noteNameForMIDI(note)).tag(note)
                                    }
                                }
                                .frame(width: 80)
                            }
                            
                            HStack {
                                Text("Range:")
                                    .font(.caption)
                                    .frame(width: 40)
                                
                                Picker("", selection: $keyRangeMin) {
                                    ForEach(0...keyRangeMax, id: \.self) { note in
                                        Text(noteNameForMIDI(note)).tag(note)
                                    }
                                }
                                .frame(width: 70)
                                
                                Text("to")
                                    .font(.caption)
                                
                                Picker("", selection: $keyRangeMax) {
                                    ForEach(keyRangeMin...127, id: \.self) { note in
                                        Text(noteNameForMIDI(note)).tag(note)
                                    }
                                }
                                .frame(width: 70)
                            }
                        }
                    }
                }
                .frame(width: 230)
                
                Divider()
                    .frame(height: 180)
                
                // Column 3 - Velocity mode and mapping button
                VStack(alignment: .leading, spacing: 12) {
                    // Velocity split mode - only show if not in Multiple Keys mode
                    if mappingMode != .multipleKeys {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Velocity Mode:")
                                .font(.caption)
                                .bold()
                            
                            Picker("", selection: $splitMode) {
                                Text("Separate").tag(VelocitySplitMode.separate)
                                Text("Crossfade").tag(VelocitySplitMode.crossfade)
                            }
                            .pickerStyle(RadioGroupPickerStyle())
                            .font(.caption)
                        }
                    }
                    
                    
                    Spacer()
                    
                    // Map button
                    Button(action: {
                        performMapping()
                    }) {
                        Label(mappingButtonText, systemImage: "layers")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasGroups || selectedGroups.isEmpty || (mappingMode == .standard && targetKeyId == nil))
                }
                .frame(width: 230)
            }
            .padding(.vertical, 8)
        } label: {
            Label("Mapping", systemImage: "layers")
                .font(.caption)
        }
        .frame(width: 750)
        .frame(minHeight: 180)
        .disabled(!hasGroups)
        .opacity(hasGroups ? 1.0 : 0.5)
    }
    
    private func performMapping() {
        let markerGroups = audioViewModel.markerGroups
        let groupsToMap = markerGroups.filter { selectedGroups.contains($0.id) }
        
        // Set the mapping mode in the sampler view model
        samplerViewModel.currentMappingMode = mappingMode
        
        if mappingMode == .multipleKeys {
            // Multiple Keys mode: Each group to its own key
            samplerViewModel.mapGroupsToMultipleKeys(
                groups: groupsToMap,
                startingKey: targetKeyId ?? 60
            )
        } else if mappingMode == .roundRobin {
            // Map to pitched range
            samplerViewModel.mapTransientGroupsToPitchedRange(
                groups: groupsToMap,
                keyRangeMin: keyRangeMin,
                keyRangeMax: keyRangeMax,
                rootKey: rootKey,
                splitMode: splitMode
            )
        } else {
            // Map to single key
            guard let keyId = targetKeyId else { return }
            samplerViewModel.mapTransientGroupsToVelocityLayers(
                groups: groupsToMap,
                toKey: keyId,
                splitMode: splitMode
            )
        }
        
        // Clear selection after mapping
        selectedGroups.removeAll()
    }
    
    // MARK: - Helper Methods
    
    private func noteNameForMIDI(_ midiNote: Int) -> String {
        let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = (midiNote / 12) - 2
        let noteIndex = midiNote % 12
        return "\(noteNames[noteIndex])\(octave)"
    }
    
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

// MARK: - Marker Handle View
struct MarkerHandle: View {
    let marker: Marker
    let markerIndex: Int
    let geometry: GeometryProxy
    @ObservedObject var audioViewModel: EnhancedAudioViewModel
    var isGrey: Bool = false

    @State private var isDragging = false
    @State private var dragStartPosition: CGFloat = 0
    @State private var dragStartSamplePosition: Int = 0
    @State private var translationBaseline: CGFloat = 0

    var body: some View {
        let x = audioViewModel.xPosition(for: marker.samplePosition, in: geometry.size.width)

        if x >= 0 && x <= geometry.size.width {
            ZStack {
                Circle()
                    .fill(isGrey ? Color.gray : (marker.group == nil ? Color.red : Color.green))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1))
                
                // Show group number if assigned
                if let group = marker.group {
                    Text("\(group)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .position(x: x, y: 6)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // Check for command modifier first
                            if NSEvent.modifierFlags.contains(.command) {
                                // Don't start dragging if command is held
                                return
                            }
                            
                            var didWarpThisTick = false

                            if !isDragging {
                                isDragging = true
                                dragStartPosition = x
                                dragStartSamplePosition = marker.samplePosition
                                translationBaseline = 0

                                // Auto-zoom if in inspect mode
                                if audioViewModel.isInspectingTransients {
                                    audioViewModel.startTransientDragInInspectMode(marker: marker)

                                    // Recompute handle X at the new zoom
                                    let oldDragStart = dragStartPosition
                                    dragStartPosition = audioViewModel.xPosition(for: marker.samplePosition,
                                                                                 in: geometry.size.width)
                                    // Warp cursor to the marker's new on-screen position
                                    if let window = NSApp.mainWindow {
                                        let markerScreenLocation = window.convertPoint(
                                            toScreen: NSPoint(
                                                x: geometry.frame(in: .global).minX + dragStartPosition + value.translation.width,
                                                y: geometry.frame(in: .global).minY + 6 + value.translation.height
                                            )
                                        )
                                        CGWarpMouseCursorPosition(CGPoint(x: markerScreenLocation.x, y: markerScreenLocation.y))
                                    }

                                    // Compensate for the *warp delta*, not the current (near-zero) translation.
                                    let warpDelta = dragStartPosition - oldDragStart
                                    translationBaseline = value.translation.width + warpDelta

                                    // Skip moving on this tick; the next onChanged will include the warp in translation.
                                    didWarpThisTick = true
                                }
                            }

                            // After the first tick, subtract the baseline so the marker doesn't jump.
                            if didWarpThisTick { return }

                            let effectiveTranslation = value.translation.width - translationBaseline
                            let newX = dragStartPosition + effectiveTranslation
                            audioViewModel.moveMarker(at: markerIndex, toX: newX, width: geometry.size.width)
                        }
                        .onEnded { _ in
                            isDragging = false
                            dragStartPosition = 0
                            dragStartSamplePosition = 0
                            translationBaseline = 0
                            if audioViewModel.isInspectingTransients {
                                audioViewModel.endTransientDragInInspectMode()
                            }
                        }
                )
                .simultaneousGesture(
                    TapGesture().modifiers(.command).onEnded {
                        audioViewModel.deleteMarker(at: markerIndex)
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
        
        // Show if end marker is visible (including at the end of file)
        if x >= 0 && x <= geometry.size.width + 10 {
            Rectangle()
                .fill(Color.gray.opacity(0.6))
                .frame(width: 10, height: 10)
                .overlay(
                    Rectangle()
                        .stroke(Color.white, lineWidth: 1)
                )
                .position(x: min(x, geometry.size.width), y: 6)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                dragStartPosition = x
                                dragStartEndPosition = endPosition
                                print("=== REGION END DRAG START ===")
                                print("Start position (x): \(x)")
                                print("Start end position (samples): \(endPosition)")
                                print("Geometry width: \(geometry.size.width)")
                            }
                            let newX = dragStartPosition + value.translation.width
                            print("Translation: \(value.translation.width), New X: \(newX)")
                            audioViewModel.moveMarkerEndPosition(at: markerIndex, toX: newX, width: geometry.size.width)
                        }
                        .onEnded { value in
                            print("=== REGION END DRAG END ===")
                            print("Final translation: \(value.translation)")
                            isDragging = false
                            dragStartPosition = 0
                            dragStartEndPosition = 0
                        }
                )
                .simultaneousGesture(
                    TapGesture().modifiers(.command).onEnded {
                        audioViewModel.resetMarkerEndPosition(at: markerIndex)
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
