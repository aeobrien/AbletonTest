import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

// MARK: - Piano Keyboard View

struct PianoKeyboardView: View {
    @Binding var keys: [PianoKey]
    @EnvironmentObject var viewModel: SamplerViewModel
    
    let onKeySelect: (Int) -> Void
    
    var body: some View {
        GeometryReader { geometry in
            let availableHeight = geometry.size.height
            
            ScrollView(.horizontal, showsIndicators: true) {
                let whiteKeys = keys.filter { $0.isWhite }
                let totalWidth = whiteKeys.reduce(0) { $0 + ($1.width ?? 0) }
                
                VStack(spacing: 0) {
                    // Octave labels (anchored to F# black keys)
                    ZStack(alignment: .topLeading) {
                        // Find visible F# black keys and place the octave label centred above each
                        ForEach(
                            keys.filter { !$0.isWhite && $0.name.hasPrefix("F#") }
                        ) { key in
                            // Centre of the F# key in the overlay coordinate space
                            let centerX = (key.xOffset ?? 0) + ((key.width ?? 0) / 2)

                            Text(getOctaveFromKeyName(key.name)) // e.g. "4", "-1", etc.
                                .font(.system(size: 12, weight: .medium))
                                // Absolute placement: x at the key centre, y mid‑height of the label strip
                                .position(x: centerX, y: 7.5)
                        }
                    }
                    // Make sure this matches the keyboard width so .position() works as intended
                    .frame(width: whiteKeys.reduce(0) { $0 + ($1.width ?? 0) }, height: 15)


                    
                    // KEYS + SEPARATORS
                    ZStack(alignment: .topLeading) {
                        // White Keys
                        HStack(spacing: 0) {
                            ForEach(keys.filter { $0.isWhite }) { key in
                                KeyView(key: key, availableHeight: availableHeight - 15) { selectedKeyId in
                                    onKeySelect(selectedKeyId)
                                }
                                .environmentObject(viewModel)
                            }
                        }

                        // Black Keys
                        ForEach(keys.filter { !$0.isWhite }) { key in
                            KeyView(key: key, availableHeight: availableHeight - 15) { selectedKeyId in
                                onKeySelect(selectedKeyId)
                            }
                            .offset(x: key.xOffset ?? 0, y: 0)
                            .zIndex(1)
                            .environmentObject(viewModel)
                        }

                        // Octave separators (B|C lines) – extend from top to bottom of KEYS only
                        GeometryReader { geo in
                            ForEach(keys.filter { $0.isWhite && $0.name.hasPrefix("C") }) { key in
                                let xPos = key.xOffset ?? 0
                                Path { p in
                                    p.move(to: CGPoint(x: xPos, y: 0))
                                    p.addLine(to: CGPoint(x: xPos, y: geo.size.height))
                                }
                                .stroke(Color.black, lineWidth: 1)
                            }
                        }
                    }
                    // 👇 Ensure the ZStack’s height equals the key area
                    .frame(height: availableHeight - 15)
             
                }
                .frame(width: max(totalWidth, 10), height: availableHeight)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        .background(Color.clear)
                )
            }
            .frame(height: geometry.size.height)
        }
    }
    
    private func getOctaveFromKeyName(_ keyName: String) -> String {
        // Extract octave number from key name (e.g., "C4" -> "4")
        let octave = keyName.filter { $0.isNumber || $0 == "-" }
        return octave.isEmpty ? "" : octave
    }
}

// MARK: - Individual Key View

struct KeyView: View {
    @EnvironmentObject var viewModel: SamplerViewModel
    let key: PianoKey
    let availableHeight: CGFloat
    let keySelectAction: (Int) -> Void
    
    @State private var isTargeted: Bool = false
    @State private var isSelected: Bool = false
    
    private var keyLabelSpace: CGFloat {
        key.isWhite ? 25 : 0
    }
    
    private var keyDrawingHeight: CGFloat {
        let heightForDrawing = availableHeight - keyLabelSpace
        let positiveHeight = max(0, heightForDrawing)
        if key.isWhite {
            return positiveHeight  // Use full available height for white keys
        } else {
            return positiveHeight * 0.5  // Black keys are 50% of white key height
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(keyColor)
                .frame(width: key.width, height: keyDrawingHeight)
                .border(borderColor, width: isSelected ? 3 : 1)
                .overlay(
                    VStack {
                        if key.hasSample {
                            Circle()
                                .fill(Color.red.opacity(0.7))
                                .frame(width: 10, height: 10)
                                .padding(5)
                        }
                        Spacer()
                    },
                    alignment: .top
                )
            
            if key.isWhite {
                Text(getNoteNameWithoutOctave(key.name))
                    .font(.system(size: 10))
                    .frame(width: key.width, height: keyLabelSpace)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 2)
                    .background(Color.white.opacity(0.001))
            }
        }
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers -> Bool in
            handleDrop(providers: providers)
        }
        .background(isTargeted ? Color.blue.opacity(0.5) : Color.clear)
        .animation(.easeInOut(duration: 0.1), value: isTargeted)
        .onTapGesture {
            keySelectAction(key.id)
        }
        .frame(width: key.width)
        .frame(height: availableHeight, alignment: .top)
        .onReceive(viewModel.$selectedKeyId) { selectedId in
            isSelected = selectedId == key.id
        }
    }
    
    private var keyColor: Color {
        if isSelected {
            return key.isWhite ? Color.blue.opacity(0.3) : Color.blue.opacity(0.6)
        }
        return key.isWhite ? Color.white : Color.black
    }
    
    private var borderColor: Color {
        isSelected ? Color.blue : Color.black
    }
    
    private func getNoteNameWithoutOctave(_ keyName: String) -> String {
        // Extract just the note name without octave (e.g., "C4" -> "C", "F#3" -> "F#")
        let noteName = keyName.filter { !$0.isNumber && $0 != "-" }
        return noteName.isEmpty ? keyName : noteName
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var collectedURLs: [URL] = []
        let dispatchGroup = DispatchGroup()
        var loadErrors = false
        
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                dispatchGroup.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item, error) in
                    defer { dispatchGroup.leave() }
                    
                    if let error = error {
                        print("Error loading dropped item: \(error)")
                        loadErrors = true
                        return
                    }
                    
                    var fileURL: URL?
                    if let urlData = item as? Data {
                        fileURL = URL(dataRepresentation: urlData, relativeTo: nil)
                    } else if let url = item as? URL {
                        fileURL = url
                    }
                    
                    if let url = fileURL, url.pathExtension.lowercased() == "wav" {
                        collectedURLs.append(url)
                    }
                }
            }
        }
        
        dispatchGroup.notify(queue: .main) {
            if !collectedURLs.isEmpty {
                viewModel.handleDroppedFiles(midiNote: key.id, fileURLs: collectedURLs)
            } else if loadErrors {
                viewModel.showError("Some dropped files could not be read.")
            } else if providers.count > 0 {
                viewModel.showError("Only WAV files can be dropped onto keys.")
            }
        }
        return true
    }
}

// MARK: - Velocity Layer Grid View

struct VelocityLayerGridView: View {
    @EnvironmentObject var viewModel: SamplerViewModel
    @Binding var velocityLayers: [VelocityLayer]
    let keyId: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Velocity Layers for \(noteNameForMIDI(keyId))")
                .font(.headline)
            
            if velocityLayers.isEmpty {
                Text("No samples mapped to this key")
                .foregroundColor(.secondary)
                .padding()
            } else {
                // Display velocity layers in reverse order (highest velocity first)
                ForEach(velocityLayers.indices.reversed(), id: \.self) { layerIndex in
                    VelocityLayerRow(
                        layer: $velocityLayers[layerIndex],
                        layerIndex: layerIndex,
                        keyId: keyId
                    )
                }
            }
            
            Button(action: addVelocityLayer) {
                Label("Add Velocity Layer", systemImage: "plus.circle")
            }
            .padding(.top)
        }
        .padding()
    }
    
    private func addVelocityLayer() {
        let newRange = VelocityRangeData(min: 0, max: 127, crossfadeMin: 0, crossfadeMax: 127)
        let newLayer = VelocityLayer(velocityRange: newRange, samples: [])
        velocityLayers.append(newLayer)
    }
    
    private func noteNameForMIDI(_ midiNote: Int) -> String {
        let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = (midiNote / 12) - 2
        let noteIndex = midiNote % 12
        return "\(noteNames[noteIndex])\(octave)"
    }
}

// MARK: - Velocity Layer Row

struct VelocityLayerRow: View {
    @Binding var layer: VelocityLayer
    let layerIndex: Int
    let keyId: Int
    @EnvironmentObject var viewModel: SamplerViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Velocity \(layer.velocityRange.min)-\(layer.velocityRange.max)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                Text("\(layer.activeSampleCount) samples")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(0..<max(layer.roundRobinCount, 1), id: \.self) { rrIndex in
                        RoundRobinSlot(
                            sample: rrIndex < layer.samples.count ? layer.samples[rrIndex] : nil,
                            rrIndex: rrIndex,
                            onDrop: { url in
                                handleSampleDrop(url: url, rrIndex: rrIndex)
                            }
                        )
                    }
                    
                    // Add slot button
                    Button(action: { addRoundRobinSlot() }) {
                        VStack {
                            Image(systemName: "plus")
                                .font(.title2)
                            Text("Add RR")
                                .font(.caption)
                        }
                        .frame(width: 80, height: 60)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(8)
                    }
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
    
    private func handleSampleDrop(url: URL, rrIndex: Int) {
        // Create sample part from dropped file
        if let audioFile = try? AVAudioFile(forReading: url) {
            let fileAttributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            
            let samplePart = MultiSamplePartData(
                name: url.deletingPathExtension().lastPathComponent,
                keyRangeMin: keyId,
                keyRangeMax: keyId,
                velocityRange: layer.velocityRange,
                sourceFileURL: url,
                segmentStartSample: 0,
                segmentEndSample: Int64(audioFile.length),
                absolutePath: url.path,
                originalAbsolutePath: url.path,
                sampleRate: audioFile.fileFormat.sampleRate,
                fileSize: fileAttributes?[.size] as? Int64,
                lastModDate: fileAttributes?[.modificationDate] as? Date,
                originalFileFrameCount: Int64(audioFile.length)
            )
            // Note: rootKey is automatically set to keyRangeMin in the struct
            
            // Update layer
            while layer.samples.count <= rrIndex {
                layer.samples.append(nil)
            }
            layer.samples[rrIndex] = samplePart
            
            // Update view model
            viewModel.multiSampleParts.append(samplePart)
        }
    }
    
    private func addRoundRobinSlot() {
        layer.samples.append(nil)
    }
}

// MARK: - Round Robin Slot

struct RoundRobinSlot: View {
    let sample: MultiSamplePartData?
    let rrIndex: Int
    let onDrop: (URL) -> Void
    
    @State private var isTargeted = false
    @State private var isPlaying = false
    @EnvironmentObject var samplerViewModel: SamplerViewModel
    
    var body: some View {
        VStack(spacing: 4) {
            if let sample = sample {
                VStack(spacing: 2) {
                    Image(systemName: isPlaying ? "waveform.circle.fill" : "waveform")
                        .font(.title3)
                        .foregroundColor(isPlaying ? .white : .primary)
                    Text(sample.name)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(isPlaying ? .white : .primary)
                }
                .frame(width: 80, height: 60)
                .background(isPlaying ? Color.blue : Color.green.opacity(0.3))
                .cornerRadius(8)
                .onTapGesture {
                    isPlaying = true
                    samplerViewModel.playSamplePart(sample)
                    
                    // Reset visual state after expected duration
                    let duration = Double(sample.segmentEndSample - sample.segmentStartSample) / (sample.sampleRate ?? 44100.0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                        isPlaying = false
                    }
                }
            } else {
                VStack(spacing: 2) {
                    Image(systemName: "plus.circle.dashed")
                        .font(.title3)
                        .foregroundColor(.gray)
                    Text("RR \(rrIndex + 1)")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .frame(width: 80, height: 60)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [5]))
                        .foregroundColor(.gray)
                )
            }
            
            Text("RR \(rrIndex + 1)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .scaleEffect(isTargeted ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isTargeted)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item, error) in
                    if let urlData = item as? Data,
                       let url = URL(dataRepresentation: urlData, relativeTo: nil),
                       url.pathExtension.lowercased() == "wav" {
                        DispatchQueue.main.async {
                            onDrop(url)
                        }
                    }
                }
            }
        }
    }
}

