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
            // Check if any sample covers this key (either directly mapped or in pitched range)
            pianoKeys[i].hasSample = multiSampleParts.contains { sample in
                if sample.isPitched {
                    // For pitched samples, check if key is within the range
                    return keyId >= sample.keyRangeMin && keyId <= sample.keyRangeMax
                } else {
                    // For non-pitched samples, only the exact key
                    return sample.keyRangeMin == keyId
                }
            }
        }
    }
    
    func selectKey(_ keyId: Int) {
        selectedKeyId = keyId
        loadVelocityLayersForKey(keyId)
    }
    
    private func loadVelocityLayersForKey(_ keyId: Int) {
        // Get all samples for this key (including pitched samples that span this key)
        let samplesForKey = multiSampleParts.filter { sample in
            if sample.isPitched {
                // For pitched samples, check if key is within the range
                return keyId >= sample.keyRangeMin && keyId <= sample.keyRangeMax
            } else {
                // For non-pitched samples, only exact matches
                return sample.keyRangeMin == keyId && sample.keyRangeMax == keyId
            }
        }
        
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
    
    /// Maps transient groups to a pitched key range
    @MainActor
    func mapTransientGroupsToPitchedRange(groups: [TransientGroup], keyRangeMin: Int, keyRangeMax: Int, rootKey: Int, splitMode: VelocitySplitMode) {
        guard let audioURL = audioViewModel?.audioURL,
              let sampleBuffer = audioViewModel?.sampleBuffer else {
            showError("No audio file loaded")
            return
        }
        
        // Clear existing layers for this range
        multiSampleParts.removeAll { part in
            part.keyRangeMin >= keyRangeMin && part.keyRangeMax <= keyRangeMax
        }
        
        // Calculate velocity ranges based on split mode
        let velocityRanges = calculateVelocityRanges(for: groups.count, mode: splitMode)
        
        // Create sample parts for each group
        for (index, group) in groups.enumerated() {
            let velocityRange = velocityRanges[index]
            
            // Create sample parts for each marker in the group (as round robins)
            for (rrIndex, marker) in group.markers.enumerated() {
                var samplePart = createSamplePartFromMarker(
                    marker: marker,
                    keyId: rootKey,  // Use rootKey for initial creation
                    velocityRange: velocityRange,
                    roundRobinIndex: rrIndex,
                    audioURL: audioURL,
                    sampleBuffer: sampleBuffer
                )
                
                // Configure for pitched mode
                samplePart.isPitched = true
                samplePart.originalRootKey = rootKey
                samplePart.keyRangeMin = keyRangeMin
                samplePart.keyRangeMax = keyRangeMax
                
                multiSampleParts.append(samplePart)
            }
        }
        
        // Reload velocity layers if we're viewing a key in this range
        if let selectedId = selectedKeyId,
           selectedId >= keyRangeMin && selectedId <= keyRangeMax {
            loadVelocityLayersForKey(selectedId)
        }
    }
    
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
        
        // Use custom end position if available
        let segmentEnd: Int64
        if let customEnd = marker.customEndPosition {
            segmentEnd = Int64(customEnd)
        } else {
            // Find the next marker position or use end of file
            let allMarkerPositions = audioViewModel?.markers.map { $0.samplePosition }.sorted() ?? []
            let nextMarkerIndex = allMarkerPositions.firstIndex { $0 > marker.samplePosition }
            if let nextIndex = nextMarkerIndex {
                segmentEnd = Int64(allMarkerPositions[nextIndex])
            } else {
                segmentEnd = Int64(sampleBuffer.samples.count)
            }
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
        // Note: rootKey is automatically set to keyRangeMin in the struct
    }
    
    /// Maps each group to its own key with round robin samples
    @MainActor
    func mapGroupsToMultipleKeys(groups: [TransientGroup], startingKey: Int) {
        guard let audioURL = audioViewModel?.audioURL,
              let sampleBuffer = audioViewModel?.sampleBuffer else {
            showError("No audio file loaded")
            return
        }
        
        var currentKey = startingKey
        
        for group in groups {
            // Skip if no markers
            guard !group.markers.isEmpty else { continue }
            
            // Ensure key is valid
            let keyId = min(max(currentKey, 0), 127)
            
            // Clear existing samples for this key
            multiSampleParts.removeAll { $0.keyRangeMin == keyId && $0.keyRangeMax == keyId }
            
            // Create sample parts for each marker in the group (as round robins)
            for (rrIndex, marker) in group.markers.enumerated() {
                let samplePart = createSamplePartFromMarker(
                    marker: marker,
                    keyId: keyId,
                    velocityRange: VelocityRangeData.fullRange,
                    roundRobinIndex: rrIndex,
                    audioURL: audioURL,
                    sampleBuffer: sampleBuffer
                )
                multiSampleParts.append(samplePart)
            }
            
            // Move to next key
            currentKey += 1
        }
        
        // Update piano key status
        updatePianoKeySampleStatus()
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
            let maxVel = i == count - 1 ? 127 : Int(Double(i + 1) * step) - 1  // Subtract 1 to avoid overlap
            
            let range: VelocityRangeData
            if mode == .crossfade {
                // Add crossfade overlap
                let crossfadeAmount = Int(step * 0.2) // 20% overlap
                let cfMin = max(0, minVel - crossfadeAmount)
                let cfMax = min(127, maxVel + crossfadeAmount)
                range = VelocityRangeData(min: minVel, max: maxVel, crossfadeMin: cfMin, crossfadeMax: cfMax)
            } else {
                // Separate mode - no overlap
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
                // Note: rootKey is automatically set to keyRangeMin in the struct
                
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
        
        // Check if we have round robins (multiple samples with same key and velocity range)
        let hasRoundRobins = detectRoundRobins()
        let roundRobinValue = hasRoundRobins ? "true" : "false"
        let roundRobinModeValue = "2" // 2 = other mode
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
                    <NumVoices Value="\(voiceCountToMenuIndex(voiceCount: 24))" />
                    <NumVoicesEnvTimeControl Value="false" />
                    <RetriggerMode Value="false" />
                    <ModulationResolution Value="2" />
                    <SpreadAmount>
                        <LomId Value="0" />
                        <Manual Value="0" />
                        <MidiControllerRange>
                            <Min Value="0" />
                            <Max Value="100" />
                        </MidiControllerRange>
                        <AutomationTarget Id="0">
                            <LockEnvelope Value="0" />
                        </AutomationTarget>
                        <ModulationTarget Id="0">
                            <LockEnvelope Value="0" />
                        </ModulationTarget>
                    </SpreadAmount>
                    <KeyZoneShift>
                        <LomId Value="0" />
                        <Manual Value="0" />
                        <MidiControllerRange>
                            <Min Value="-48" />
                            <Max Value="48" />
                        </MidiControllerRange>
                        <AutomationTarget Id="0">
                            <LockEnvelope Value="0" />
                        </AutomationTarget>
                        <ModulationTarget Id="0">
                            <LockEnvelope Value="0" />
                        </ModulationTarget>
                    </KeyZoneShift>
                    <PortamentoMode>
                        <LomId Value="0" />
                        <Manual Value="0" />
                        <AutomationTarget Id="0">
                            <LockEnvelope Value="0" />
                        </AutomationTarget>
                        <MidiControllerRange>
                            <Min Value="0" />
                            <Max Value="2" />
                        </MidiControllerRange>
                    </PortamentoMode>
                    <PortamentoTime>
                        <LomId Value="0" />
                        <Manual Value="50" />
                        <MidiControllerRange>
                            <Min Value="0.1000000015" />
                            <Max Value="10000" />
                        </MidiControllerRange>
                        <AutomationTarget Id="0">
                            <LockEnvelope Value="0" />
                        </AutomationTarget>
                        <ModulationTarget Id="0">
                            <LockEnvelope Value="0" />
                        </ModulationTarget>
                    </PortamentoTime>
                    <PitchBendRange Value="2" />
                    <MpePitchBendRange Value="48" />
                    <ScrollPosition Value="0" />
                    <EnvScale>
                        <EnvTime>
                            <LomId Value="0" />
                            <Manual Value="0" />
                            <MidiControllerRange>
                                <Min Value="-100" />
                                <Max Value="100" />
                            </MidiControllerRange>
                            <AutomationTarget Id="0">
                                <LockEnvelope Value="0" />
                            </AutomationTarget>
                            <ModulationTarget Id="0">
                                <LockEnvelope Value="0" />
                            </ModulationTarget>
                        </EnvTime>
                        <EnvTimeKeyScale>
                            <LomId Value="0" />
                            <Manual Value="0" />
                            <MidiControllerRange>
                                <Min Value="-100" />
                                <Max Value="100" />
                            </MidiControllerRange>
                            <AutomationTarget Id="0">
                                <LockEnvelope Value="0" />
                            </AutomationTarget>
                            <ModulationTarget Id="0">
                                <LockEnvelope Value="0" />
                            </ModulationTarget>
                        </EnvTimeKeyScale>
                        <EnvTimeIncludeAttack>
                            <LomId Value="0" />
                            <Manual Value="true" />
                            <AutomationTarget Id="0">
                                <LockEnvelope Value="0" />
                            </AutomationTarget>
                            <MidiCCOnOffThresholds>
                                <Min Value="64" />
                                <Max Value="127" />
                            </MidiCCOnOffThresholds>
                        </EnvTimeIncludeAttack>
                    </EnvScale>
                    <IsSimpler Value="false" />
                    <PlaybackMode Value="0" />
                    <LegacyMode Value="false" />
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
                                        <RelativePathType Value="3" />
                                        <RelativePath Value="Samples/Imported/\(relativePath)" />
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
                                <RootKey Value="\(part.rootKey)" />
                                <Detune Value="\(part.detune)" />
                                <TuneScale Value="\(part.tuneScale)" />
                                <Panorama Value="\(part.panorama)" />
                                <Volume Value="\(part.volume)" />
                                <Link Value="\(part.link ? "true" : "false")" />
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
    
    // MARK: - Helper Methods
    
    private func voiceCountToMenuIndex(voiceCount: Int) -> Int {
        // Ableton's voice menu options: 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 32
        let voiceOptions = [1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 32]
        
        // Find the index of the voice count, default to 13 (24 voices) if not found
        if let index = voiceOptions.firstIndex(of: voiceCount) {
            return index
        } else {
            // Default to 24 voices (index 13)
            return 13
        }
    }
    
    private func detectRoundRobins() -> Bool {
        // Group samples by key and velocity range
        var groupedSamples: [String: Int] = [:]
        
        for part in multiSampleParts {
            let key = "\(part.keyRangeMin)-\(part.keyRangeMax)_\(part.velocityRange.min)-\(part.velocityRange.max)"
            groupedSamples[key, default: 0] += 1
        }
        
        // If any group has more than 1 sample, we have round robins
        return groupedSamples.values.contains { $0 > 1 }
    }
    
    // MARK: - Audio Playback
    
    private var playbackTimer: Timer?
    @Published var currentlyPlayingSampleId: UUID? = nil
    
    @MainActor
    func playSamplePart(_ samplePart: MultiSamplePartData) {
        guard let audioViewModel = audioViewModel,
              let player = audioViewModel.audioPlayer,
              let buffer = audioViewModel.sampleBuffer else {
            print("Cannot play sample: missing audio components")
            return
        }
        
        // Cancel any existing playback timer (monophonic behavior)
        playbackTimer?.invalidate()
        
        // If a sample is already playing, apply fade out to prevent click
        if currentlyPlayingSampleId != nil && player.isPlaying {
            // Apply 10ms fade out
            let fadeOutDuration = 0.01 // 10ms
            player.setVolume(0.0, fadeDuration: fadeOutDuration)
            
            // Stop after fade completes
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeOutDuration) {
                player.stop()
                player.setVolume(1.0, fadeDuration: 0) // Reset volume
            }
        }
        
        // Set currently playing sample
        currentlyPlayingSampleId = samplePart.id
        
        // Calculate time boundaries
        let sampleRate = player.format.sampleRate
        let startTime = TimeInterval(samplePart.segmentStartSample) / sampleRate
        let endTime = TimeInterval(samplePart.segmentEndSample) / sampleRate
        let duration = endTime - startTime
        
        // Start playback after any fade out completes
        let playbackDelay = player.isPlaying ? 0.01 : 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + playbackDelay) {
            player.currentTime = startTime
            player.play()
            audioViewModel.isPlaying = true
        }
        
        // Use a timer to stop at the exact end time
        playbackTimer = Timer.scheduledTimer(withTimeInterval: duration + playbackDelay, repeats: false) { _ in
            Task { @MainActor in
                if player.isPlaying && self.currentlyPlayingSampleId == samplePart.id {
                    player.stop()
                    audioViewModel.isPlaying = false
                    self.currentlyPlayingSampleId = nil
                }
            }
        }
    }
    
    // MARK: - Error Handling
    
    func showError(_ message: String) {
        errorAlertMessage = message
    }
}