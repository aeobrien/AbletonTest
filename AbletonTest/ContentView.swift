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
                
                Button(action: {
                    audioViewModel.detectTransients()
                }) {
                    Text("Detect Transients")
                }
                .buttonStyle(OrangeButtonStyle())
                .disabled(audioViewModel.sampleBuffer == nil)
                
                Button(action: { audioViewModel.showImporter = true }) {
                    Label("Import WAV", systemImage: "waveform")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            
            // Minimap
            VStack(alignment: .leading, spacing: 4) {
                Text("Overview")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                
                MinimapView(viewModel: audioViewModel)
                    .padding(.horizontal)
            }
            
            // Main waveform
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Waveform")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    if audioViewModel.totalSamples > 0 {
                        Text("Visible: \(audioViewModel.visibleStart)-\(audioViewModel.visibleStart + audioViewModel.visibleLength)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
                
                EnhancedWaveformView(viewModel: audioViewModel)
                    .padding(.horizontal)
                    .clipped()
            }
            
            // Controls
            WaveformControls(viewModel: audioViewModel)
                .padding(.vertical, 8)
                .background(Color.gray.opacity(0.05))
                .cornerRadius(8)
                .padding(.horizontal)
            
            // Action buttons
            HStack {
                Button(action: {
                    showingGroupMapper = true
                }) {
                    Label("Map Groups to Keys", systemImage: "piano")
                }
                .disabled(audioViewModel.markers.filter { $0.group != nil }.isEmpty)
                
                Spacer()
                
                Button(action: {
                    audioViewModel.markers.removeAll()
                    audioViewModel.transientMarkers.removeAll()
                    audioViewModel.hasDetectedTransients = false
                }) {
                    Text("Clear All")
                }
                .foregroundColor(.red)
                .disabled(audioViewModel.markers.isEmpty)
            }
            .padding(.horizontal)
            
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
            .frame(height: 200)
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
                    if let dropInfo = samplerViewModel.pendingDropInfo {
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