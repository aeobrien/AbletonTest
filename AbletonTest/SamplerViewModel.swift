import SwiftUI
import AVFoundation
import Foundation
import Compression

// MARK: - Sampler View Model

/// Manages the integration between transient detection groups and the keyboard/velocity layer system
class SamplerViewModel: ObservableObject {
    
    // MARK: - Published Properties
    
    /// Holds all the individual sample parts that will be included in the ADV file
    @Published var multiSampleParts: [MultiSamplePartData] = [] {
        didSet {
            updatePianoKeySampleStatus()
        }
    }
    
    /// Holds the state for the visual piano keyboard
    @Published var pianoKeys: [PianoKey] = []
    
    /// Currently selected key on the keyboard
    @Published var selectedKeyId: Int? = nil
    
    /// Velocity layers for the currently selected key
    @Published var velocityLayers: [VelocityLayer] = []
    
    /// Controls the presentation of the modal asking how to split velocities
    @Published var showingVelocitySplitPrompt = false
    
    /// Temporarily stores information about the files dropped onto a key zone
    @Published var pendingDropInfo: (midiNote: Int, fileURLs: [URL])? = nil
    
    /// Controls the presentation of the save panel
    @Published var showingSavePanel = false
    
    /// Holds the message for any error alert
    @Published var errorAlertMessage: String? = nil
    
    /// Current mapping mode
    @Published var currentMappingMode: MappingMode = .standard
    
    /// Reference to the audio view model for transient detection
    var audioViewModel: EnhancedAudioViewModel?
    
    // MARK: - Initialization
    
    init() {
        self.pianoKeys = generatePianoKeys()
    }
    
    // MARK: - Piano Key Management
    
    private func updatePianoKeySampleStatus() {
        for i in pianoKeys.indices {
            let keyId = pianoKeys[i].id
            pianoKeys[i].hasSample = multiSampleParts.contains { $0.keyRangeMin == keyId }
        }
    }
    
    func selectKey(_ keyId: Int) {
        selectedKeyId = keyId
        loadVelocityLayersForKey(keyId)
    }
    
    private func loadVelocityLayersForKey(_ keyId: Int) {
        // Get all samples for this key
        let samplesForKey = multiSampleParts.filter { $0.keyRangeMin == keyId && $0.keyRangeMax == keyId }
        
        // Group by velocity range
        var layersByRange: [VelocityRangeData: [MultiSamplePartData]] = [:]
        for sample in samplesForKey {
            if layersByRange[sample.velocityRange] == nil {
                layersByRange[sample.velocityRange] = []
            }
            layersByRange[sample.velocityRange]?.append(sample)
        }
        
        // Create velocity layers
        velocityLayers = layersByRange.map { range, samples in
            VelocityLayer(velocityRange: range, samples: samples)
        }.sorted { $0.velocityRange.min < $1.velocityRange.min }
    }
    
    // MARK: - Transient Group Integration
    
    /// Maps transient groups to velocity layers on the selected key
    @MainActor
    func mapTransientGroupsToVelocityLayers(groups: [TransientGroup], toKey keyId: Int, splitMode: VelocitySplitMode) {
        guard let audioURL = audioViewModel?.audioURL,
              let sampleBuffer = audioViewModel?.sampleBuffer else {
            showError("No audio file loaded")
            return
        }
        
        // Clear existing layers for this key
        multiSampleParts.removeAll { $0.keyRangeMin == keyId }
        
        // Calculate velocity ranges based on split mode
        let velocityRanges = calculateVelocityRanges(for: groups.count, mode: splitMode)
        
        // Create sample parts for each group
        for (index, group) in groups.enumerated() {
            let velocityRange = velocityRanges[index]
            
            // Create sample parts for each marker in the group (as round robins)
            for (rrIndex, marker) in group.markers.enumerated() {
                let samplePart = createSamplePartFromMarker(
                    marker: marker,
                    keyId: keyId,
                    velocityRange: velocityRange,
                    roundRobinIndex: rrIndex,
                    audioURL: audioURL,
                    sampleBuffer: sampleBuffer
                )
                multiSampleParts.append(samplePart)
            }
        }
        
        // Reload velocity layers for the current key
        if selectedKeyId == keyId {
            loadVelocityLayersForKey(keyId)
        }
    }
    
    @MainActor
    private func createSamplePartFromMarker(marker: Marker, keyId: Int, velocityRange: VelocityRangeData, roundRobinIndex: Int, audioURL: URL, sampleBuffer: SampleBuffer) -> MultiSamplePartData {
        // Calculate segment boundaries
        let segmentStart = Int64(marker.samplePosition)
        
        // Find the next marker position or use end of file
        let allMarkerPositions = audioViewModel?.markers.map { $0.samplePosition }.sorted() ?? []
        let nextMarkerIndex = allMarkerPositions.firstIndex { $0 > marker.samplePosition }
        let segmentEnd: Int64
        if let nextIndex = nextMarkerIndex {
            segmentEnd = Int64(allMarkerPositions[nextIndex])
        } else {
            segmentEnd = Int64(sampleBuffer.samples.count)
        }
        
        // Get audio file metadata
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: audioURL.path)
        let fileSize = fileAttributes?[.size] as? Int64 ?? 0
        let lastModDate = fileAttributes?[.modificationDate] as? Date ?? Date()
        
        // Get sample rate from audio file
        var sampleRate: Double = 44100 // Default
        if let audioFile = try? AVAudioFile(forReading: audioURL) {
            sampleRate = audioFile.fileFormat.sampleRate
        }
        
        return MultiSamplePartData(
            name: audioURL.deletingPathExtension().lastPathComponent, // Use original filename, not a custom name
            keyRangeMin: keyId,
            keyRangeMax: keyId,
            velocityRange: velocityRange,
            sourceFileURL: audioURL,
            segmentStartSample: segmentStart,
            segmentEndSample: segmentEnd,
            relativePath: audioURL.lastPathComponent, // Just the filename since it's in the same directory
            absolutePath: audioURL.path,
            originalAbsolutePath: audioURL.path,
            sampleRate: sampleRate,
            fileSize: fileSize,
            lastModDate: lastModDate,
            originalFileFrameCount: Int64(sampleBuffer.samples.count)
        )
    }
    
    private func calculateVelocityRanges(for count: Int, mode: VelocitySplitMode) -> [VelocityRangeData] {
        guard count > 0 else { return [] }
        
        if count == 1 {
            return [VelocityRangeData.fullRange]
        }
        
        var ranges: [VelocityRangeData] = []
        let step = 127.0 / Double(count)
        
        for i in 0..<count {
            let minVel = Int(Double(i) * step)
            let maxVel = i == count - 1 ? 127 : Int(Double(i + 1) * step)
            
            let range: VelocityRangeData
            if mode == .crossfade {
                // Add crossfade overlap
                let crossfadeAmount = Int(step * 0.2) // 20% overlap
                let cfMin = max(0, minVel - crossfadeAmount)
                let cfMax = min(127, maxVel + crossfadeAmount)
                range = VelocityRangeData(min: minVel, max: maxVel, crossfadeMin: cfMin, crossfadeMax: cfMax)
            } else {
                range = VelocityRangeData(min: minVel, max: maxVel, crossfadeMin: minVel, crossfadeMax: maxVel)
            }
            ranges.append(range)
        }
        
        return ranges
    }
    
    private func noteNameForMIDI(_ midiNote: Int) -> String {
        let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = (midiNote / 12) - 2
        let noteIndex = midiNote % 12
        return "\(noteNames[noteIndex])\(octave)"
    }
    
    // MARK: - File Import
    
    func handleDroppedFiles(midiNote: Int, fileURLs: [URL]) {
        pendingDropInfo = (midiNote, fileURLs)
        showingVelocitySplitPrompt = true
    }
    
    func importBatchSamples(for midiNote: Int, samples: [(url: URL, velocityRange: (min: Int, max: Int), roundRobinIndex: Int)]) {
        for sample in samples {
            let velocityRange = VelocityRangeData(
                min: sample.velocityRange.min,
                max: sample.velocityRange.max,
                crossfadeMin: sample.velocityRange.min,
                crossfadeMax: sample.velocityRange.max
            )
            
            if let audioFile = try? AVAudioFile(forReading: sample.url) {
                let fileAttributes = try? FileManager.default.attributesOfItem(atPath: sample.url.path)
                
                let samplePart = MultiSamplePartData(
                    name: sample.url.deletingPathExtension().lastPathComponent,
                    keyRangeMin: midiNote,
                    keyRangeMax: midiNote,
                    velocityRange: velocityRange,
                    sourceFileURL: sample.url,
                    segmentStartSample: 0,
                    segmentEndSample: Int64(audioFile.length),
                    absolutePath: sample.url.path,
                    originalAbsolutePath: sample.url.path,
                    sampleRate: audioFile.fileFormat.sampleRate,
                    fileSize: fileAttributes?[.size] as? Int64,
                    lastModDate: fileAttributes?[.modificationDate] as? Date,
                    originalFileFrameCount: Int64(audioFile.length)
                )
                
                multiSampleParts.append(samplePart)
            }
        }
        
        // Reload velocity layers if we're importing to the selected key
        if selectedKeyId == midiNote {
            loadVelocityLayersForKey(midiNote)
        }
    }
    
    // MARK: - XML Generation and Export
    
    func saveToADVFile() {
        showingSavePanel = true
        
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType(filenameExtension: "adv")!]
        savePanel.nameFieldStringValue = "MySampler.adv"
        savePanel.title = "Save Ableton Sampler Preset"
        savePanel.message = "Choose where to save your sampler preset file"
        
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                self.performSave(to: url)
            }
            self.showingSavePanel = false
        }
    }
    
    private func performSave(to url: URL) {
        do {
            let projectDir = url.deletingLastPathComponent()
            
            // Update paths in multiSampleParts
            for i in multiSampleParts.indices {
                let sourceURL = multiSampleParts[i].sourceFileURL
                let relativePath = sourceURL.lastPathComponent
                multiSampleParts[i].relativePath = relativePath // Just the filename
            }
            
            // Generate XML
            let xmlString = generateFullXmlString(projectPath: projectDir.path)
            
            guard let xmlData = xmlString.data(using: .utf8) else {
                throw NSError(domain: "SamplerViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not convert XML to data"])
            }
            
            // Compress with gzip
            guard let compressedData = gzipData(xmlData) else {
                throw NSError(domain: "SamplerViewModel", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to compress XML data"])
            }
            
            // Write to file
            try compressedData.write(to: url)
            
            print("Successfully saved ADV file to: \(url.path)")
        } catch {
            showError("Failed to save ADV file: \(error.localizedDescription)")
        }
    }
    
    private func gzipData(_ data: Data) -> Data? {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFilename = UUID().uuidString + ".xml"
        let tempFileURL = tempDir.appendingPathComponent(tempFilename)
        var compressedData: Data?
        
        do {
            try data.write(to: tempFileURL, options: .atomicWrite)
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            // Use -c to output to stdout
            // Use -f to force overwrite if temp file somehow exists
            // Use -k to keep the original temp file (we'll delete it manually)
            process.arguments = ["-c", "-f", "-k", tempFileURL.path]
            
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            let errorPipe = Pipe()
            process.standardError = errorPipe
            
            try process.run()
            process.waitUntilExit()
            
            // Read stderr before checking termination status
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            if let errorString = String(data: errorData, encoding: .utf8), !errorString.isEmpty {
                print("Gzip stderr: \(errorString)")
            }
            
            if process.terminationStatus == 0 {
                compressedData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                print("Gzip process completed successfully.")
            } else {
                print("Error: gzip process failed with status \(process.terminationStatus)")
            }
            
        } catch {
            print("Error during gzip process: \(error)")
        }
        
        // Clean up temporary file
        do {
            try FileManager.default.removeItem(at: tempFileURL)
        } catch {
            print("Warning: Could not remove temporary gzip input file at \(tempFileURL.path): \(error)")
        }
        
        return compressedData
    }
    
    func generateFullXmlString(projectPath: String) -> String {
        let samplePartsXml = generateSamplePartsXml(projectPath: projectPath)
        
        let roundRobinValue = currentMappingMode == .roundRobin ? "true" : "false"
        let roundRobinModeValue = currentMappingMode == .roundRobin ? "2" : "0"
        let randomSeed = Int.random(in: 1...1000000000)
        
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <Ableton MajorVersion="5" MinorVersion="12.0_12120" SchemaChangeCount="4" Creator="AbletonTest" Revision="Generated">
            <MultiSampler>
                <LomId Value="0" />
                <Player>
                    <MultiSampleMap>
                        <SampleParts>
        \(samplePartsXml)
                        </SampleParts>
                        <LoadInRam Value="false" />
                        <LayerCrossfade Value="0" />
                        <SourceContext />
                        <RoundRobin Value="\(roundRobinValue)" />
                        <RoundRobinMode Value="\(roundRobinModeValue)" />
                        <RoundRobinResetPeriod Value="0" />
                        <RoundRobinRandomSeed Value="\(randomSeed)" />
                    </MultiSampleMap>
                </Player>
                <Pitch>
                    <TransposeKey>
                        <Manual Value="0" />
                    </TransposeKey>
                    <TransposeFine>
                        <Manual Value="0" />
                    </TransposeFine>
                </Pitch>
                <Filter>
                    <IsOn><Manual Value="true" /></IsOn>
                    <Slot>
                        <Value>
                            <SimplerFilter Id="0">
                                <Type><Manual Value="0" /></Type>
                                <Freq><Manual Value="22000" /></Freq>
                                <Res><Manual Value="0" /></Res>
                                <ModByPitch>
                                    <LomId Value="0" />
                                    <Manual Value="0" />
                                </ModByPitch>
                            </SimplerFilter>
                        </Value>
                    </Slot>
                </Filter>
                <VolumeAndPan>
                    <Volume><Manual Value="-12" /></Volume>
                    <Panorama><Manual Value="0" /></Panorama>
                </VolumeAndPan>
                <Globals>
                    <NumVoices Value="32" />
                </Globals>
            </MultiSampler>
        </Ableton>
        """
    }
    
    private func generateSamplePartsXml(projectPath: String) -> String {
        return multiSampleParts.map { generateMultiSamplePartXml($0, projectPath: projectPath) }.joined(separator: "\n")
    }
    
    private func generateMultiSamplePartXml(_ part: MultiSamplePartData, projectPath: String) -> String {
        let relativePath = part.relativePath ?? part.sourceFileURL.lastPathComponent
        
        return """
                            <MultiSamplePart Id="\(Int.random(in: 1000...99999))" HasImportedSlicePoints="true" NeedsAnalysisData="true">
                                <LomId Value="0" />
                                <Name Value="\(part.name)" />
                                <SampleRef>
                                    <FileRef>
                                        <RelativePathType Value="5" />
                                        <RelativePath Value="\(relativePath)" />
                                        <Path Value="\(part.absolutePath)" />
                                        <Type Value="2" />
                                        <LivePackName Value="" />
                                        <LivePackId Value="" />
                                        <OriginalFileSize Value="\(part.fileSize ?? 0)" />
                                        <OriginalCrc Value="\(part.crc ?? 0)" />
                                    </FileRef>
                                    <LastModDate Value="\(Int(part.lastModDate?.timeIntervalSince1970 ?? 0))" />
                                    <SourceContext />
                                    <SampleUsageHint Value="0" />
                                    <DefaultDuration Value="\(part.originalFileFrameCount ?? 0)" />
                                    <DefaultSampleRate Value="\(Int(part.sampleRate ?? 44100))" />
                                </SampleRef>
                                <KeyRange>
                                    <Min Value="\(part.keyRangeMin)" />
                                    <Max Value="\(part.keyRangeMax)" />
                                    <CrossfadeMin Value="\(part.keyRangeMin)" />
                                    <CrossfadeMax Value="\(part.keyRangeMax)" />
                                </KeyRange>
                                <VelocityRange>
                                    <Min Value="\(part.velocityRange.min)" />
                                    <Max Value="\(part.velocityRange.max)" />
                                    <CrossfadeMin Value="\(part.velocityRange.crossfadeMin)" />
                                    <CrossfadeMax Value="\(part.velocityRange.crossfadeMax)" />
                                </VelocityRange>
                                <SampleStart Value="\(part.sampleStart)" />
                                <SampleEnd Value="\(part.sampleEnd)" />
                                <SustainLoop>
                                    <Start Value="\(part.sustainLoopStart ?? 0)" />
                                    <End Value="\(part.sustainLoopEnd ?? 0)" />
                                    <Mode Value="\(part.sustainLoopMode)" />
                                    <Crossfade Value="\(part.sustainLoopCrossfade)" />
                                    <Detune Value="\(part.sustainLoopDetune)" />
                                </SustainLoop>
                                <ReleaseLoop>
                                    <Start Value="\(part.releaseLoopStart ?? 0)" />
                                    <End Value="\(part.releaseLoopEnd ?? 0)" />
                                    <Mode Value="\(part.releaseLoopMode)" />
                                    <Crossfade Value="\(part.releaseLoopCrossfade)" />
                                    <Detune Value="\(part.releaseLoopDetune)" />
                                </ReleaseLoop>
                            </MultiSamplePart>
        """
    }
    
    // MARK: - Error Handling
    
    func showError(_ message: String) {
        errorAlertMessage = message
    }
}