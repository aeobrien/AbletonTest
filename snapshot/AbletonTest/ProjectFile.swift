import Foundation
import SwiftUI

// MARK: - Project File Structure

/// The top-level structure for saved project files
struct AbletonTestProject: Codable {
    let version: String = "1.0"
    let createdDate: Date
    let modifiedDate: Date
    
    // Audio file reference
    let audioFileBookmark: Data?
    let audioFileName: String
    let audioFilePath: String
    let sampleRate: Double
    let totalSamples: Int
    
    // Markers and transients
    let markers: [SavedMarker]
    let transientMarkers: [Int]
    let transientThreshold: Double
    let transientOffsetMs: Double
    let selectedDetectionAlgorithm: String
    
    // Zones
    let zones: [SavedZone]
    let currentZoneIndex: Int
    let zoneDataStorage: [String: SavedZoneData] // UUID string -> zone data
    
    // View state
    let zoomLevel: Double
    let scrollOffset: Double
    let yScale: Double
    let showTransientMarkers: Bool
    let showRegionHighlights: Bool
    
    // Sampler data
    let multiSampleParts: [SavedMultiSamplePart]
    let currentMappingMode: String
    
    // Master envelope
    let masterEnvelopeAttack: Double
    let masterEnvelopeDecay: Double
    let masterEnvelopeSustain: Double
    let masterEnvelopeRelease: Double
}

// MARK: - Saved Data Structures

struct SavedMarker: Codable {
    let id: String // UUID string
    let samplePosition: Int
    let group: Int?
    let customEndPosition: Int?
}

struct SavedZone: Codable {
    let id: String // UUID string
    let startSample: Int
    let endSample: Int
    let name: String
    let isIgnored: Bool
}

struct SavedZoneData: Codable {
    let markers: [SavedMarker]
    let transientMarkers: [Int]
    let tempSelection: SavedRange?
    let pendingGroupAssignment: SavedRange?
    let hasDetectedTransients: Bool
}

struct SavedRange: Codable {
    let lowerBound: Int
    let upperBound: Int
}

struct SavedMultiSamplePart: Codable {
    let id: String // UUID string
    let name: String
    let keyRangeMin: Int
    let keyRangeMax: Int
    let velocityRangeMin: Int
    let velocityRangeMax: Int
    let velocityCrossfadeMin: Int
    let velocityCrossfadeMax: Int
    let sourceFileBookmark: Data?
    let sourceFileName: String
    let sourceFilePath: String
    let segmentStartSample: Int64
    let segmentEndSample: Int64
    let relativePath: String?
    let absolutePath: String
    let originalAbsolutePath: String
    let sampleRate: Double?
    let fileSize: Int64?
    let crc: UInt32?
    let lastModDate: Date?
    let originalFileFrameCount: Int64?
    let isPitched: Bool
    let originalRootKey: Int?
    let detune: Int
    let tuneScale: Int
    let panorama: Int
    let volume: Double
    let link: Bool
    let sustainLoopStart: Int64?
    let sustainLoopEnd: Int64?
    let sustainLoopMode: Int
    let sustainLoopCrossfade: Double
    let sustainLoopDetune: Double
    let releaseLoopStart: Int64?
    let releaseLoopEnd: Int64?
    let releaseLoopMode: Int
    let releaseLoopCrossfade: Double
    let releaseLoopDetune: Double
}

// MARK: - Project File Manager

@MainActor
class ProjectFileManager: ObservableObject {
    static let shared = ProjectFileManager()
    
    @Published var currentProjectURL: URL?
    @Published var hasUnsavedChanges = false
    
    private init() {}
    
    // MARK: - Save Project
    
    func saveProject(audioViewModel: EnhancedAudioViewModel, samplerViewModel: SamplerViewModel, to url: URL) throws {
        // Create audio file bookmark
        let audioBookmark: Data?
        if let audioURL = audioViewModel.audioURL {
            audioBookmark = try audioURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        } else {
            audioBookmark = nil
        }
        
        // Convert markers
        let savedMarkers = audioViewModel.markers.map { marker in
            SavedMarker(
                id: marker.id.uuidString,
                samplePosition: marker.samplePosition,
                group: marker.group,
                customEndPosition: marker.customEndPosition
            )
        }
        
        // Convert zones
        let savedZones = audioViewModel.zones.map { zone in
            SavedZone(
                id: zone.id.uuidString,
                startSample: zone.startSample,
                endSample: zone.endSample,
                name: zone.name,
                isIgnored: zone.isIgnored
            )
        }
        
        // Convert zone data storage
        let savedZoneData = audioViewModel.zoneDataStorage.compactMapValues { zoneData in
            SavedZoneData(
                markers: zoneData.markers.map { marker in
                    SavedMarker(
                        id: marker.id.uuidString,
                        samplePosition: marker.samplePosition,
                        group: marker.group,
                        customEndPosition: marker.customEndPosition
                    )
                },
                transientMarkers: Array(zoneData.transientMarkers),
                tempSelection: zoneData.tempSelection.map { SavedRange(lowerBound: $0.lowerBound, upperBound: $0.upperBound) },
                pendingGroupAssignment: zoneData.pendingGroupAssignment.map { SavedRange(lowerBound: $0.lowerBound, upperBound: $0.upperBound) },
                hasDetectedTransients: zoneData.hasDetectedTransients
            )
        }
        
        // Convert zone data storage keys to strings
        var stringKeyedZoneData: [String: SavedZoneData] = [:]
        for (key, value) in savedZoneData {
            stringKeyedZoneData[key.uuidString] = value
        }
        
        // Convert multi sample parts
        let savedSampleParts = try samplerViewModel.multiSampleParts.map { part in
            // Create bookmark for source file if it exists
            let sourceBookmark = try? part.sourceFileURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            
            return SavedMultiSamplePart(
                id: part.id.uuidString,
                name: part.name,
                keyRangeMin: part.keyRangeMin,
                keyRangeMax: part.keyRangeMax,
                velocityRangeMin: part.velocityRange.min,
                velocityRangeMax: part.velocityRange.max,
                velocityCrossfadeMin: part.velocityRange.crossfadeMin,
                velocityCrossfadeMax: part.velocityRange.crossfadeMax,
                sourceFileBookmark: sourceBookmark,
                sourceFileName: part.sourceFileURL.lastPathComponent,
                sourceFilePath: part.sourceFileURL.path,
                segmentStartSample: part.segmentStartSample,
                segmentEndSample: part.segmentEndSample,
                relativePath: part.relativePath,
                absolutePath: part.absolutePath,
                originalAbsolutePath: part.originalAbsolutePath,
                sampleRate: part.sampleRate,
                fileSize: part.fileSize,
                crc: part.crc,
                lastModDate: part.lastModDate,
                originalFileFrameCount: part.originalFileFrameCount,
                isPitched: part.isPitched,
                originalRootKey: part.originalRootKey,
                detune: part.detune,
                tuneScale: part.tuneScale,
                panorama: part.panorama,
                volume: part.volume,
                link: part.link,
                sustainLoopStart: part.sustainLoopStart,
                sustainLoopEnd: part.sustainLoopEnd,
                sustainLoopMode: part.sustainLoopMode,
                sustainLoopCrossfade: part.sustainLoopCrossfade,
                sustainLoopDetune: part.sustainLoopDetune,
                releaseLoopStart: part.releaseLoopStart,
                releaseLoopEnd: part.releaseLoopEnd,
                releaseLoopMode: part.releaseLoopMode,
                releaseLoopCrossfade: part.releaseLoopCrossfade,
                releaseLoopDetune: part.releaseLoopDetune
            )
        }
        
        // Create project structure
        let project = AbletonTestProject(
            createdDate: currentProjectURL == url ? Date() : Date(),
            modifiedDate: Date(),
            audioFileBookmark: audioBookmark,
            audioFileName: audioViewModel.audioURL?.lastPathComponent ?? "",
            audioFilePath: audioViewModel.audioURL?.path ?? "",
            sampleRate: audioViewModel.sampleRate,
            totalSamples: audioViewModel.totalSamples,
            markers: savedMarkers,
            transientMarkers: Array(audioViewModel.transientMarkers),
            transientThreshold: audioViewModel.transientThreshold,
            transientOffsetMs: audioViewModel.transientOffsetMs,
            selectedDetectionAlgorithm: audioViewModel.selectedDetectionAlgorithm.rawValue,
            zones: savedZones,
            currentZoneIndex: audioViewModel.currentZoneIndex,
            zoneDataStorage: stringKeyedZoneData,
            zoomLevel: audioViewModel.zoomLevel,
            scrollOffset: audioViewModel.scrollOffset,
            yScale: audioViewModel.yScale,
            showTransientMarkers: audioViewModel.showTransientMarkers,
            showRegionHighlights: audioViewModel.showRegionHighlights,
            multiSampleParts: savedSampleParts,
            currentMappingMode: samplerViewModel.currentMappingMode.rawValue,
            masterEnvelopeAttack: samplerViewModel.masterEnvelopeAttack,
            masterEnvelopeDecay: samplerViewModel.masterEnvelopeDecay,
            masterEnvelopeSustain: samplerViewModel.masterEnvelopeSustain,
            masterEnvelopeRelease: samplerViewModel.masterEnvelopeRelease
        )
        
        // Encode and save
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        
        let data = try encoder.encode(project)
        try data.write(to: url)
        
        currentProjectURL = url
        hasUnsavedChanges = false
    }
    
    // MARK: - Load Project
    
    func loadProject(from url: URL, audioViewModel: EnhancedAudioViewModel, samplerViewModel: SamplerViewModel) throws {
        // Read and decode project file
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let project = try decoder.decode(AbletonTestProject.self, from: data)
        
        // Load audio file
        if let bookmarkData = project.audioFileBookmark {
            var isStale = false
            let audioURL = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            
            if audioURL.startAccessingSecurityScopedResource() {
                audioViewModel.processImport(from: audioURL, with: [], ignoredZones: Set())
            }
        }
        
        // Restore markers
        audioViewModel.markers = project.markers.map { savedMarker in
            Marker(
                samplePosition: savedMarker.samplePosition,
                group: savedMarker.group,
                customEndPosition: savedMarker.customEndPosition
            )
        }
        
        // Restore transient markers
        audioViewModel.transientMarkers = Set(project.transientMarkers)
        audioViewModel.transientThreshold = project.transientThreshold
        audioViewModel.transientOffsetMs = project.transientOffsetMs
        audioViewModel.selectedDetectionAlgorithm = TransientDetectionAlgorithm(rawValue: project.selectedDetectionAlgorithm) ?? .multiscaleTimeDomain
        audioViewModel.hasDetectedTransients = !project.transientMarkers.isEmpty
        
        // Restore zones
        audioViewModel.zones = project.zones.map { savedZone in
            AudioZone(
                startSample: savedZone.startSample,
                endSample: savedZone.endSample,
                name: savedZone.name,
                isIgnored: savedZone.isIgnored
            )
        }
        audioViewModel.currentZoneIndex = project.currentZoneIndex
        
        // Restore zone data storage
        for (keyString, savedData) in project.zoneDataStorage {
            if let uuid = UUID(uuidString: keyString) {
                let zoneData = EnhancedAudioViewModel.ZoneData(
                    markers: savedData.markers.map { savedMarker in
                        Marker(
                            samplePosition: savedMarker.samplePosition,
                            group: savedMarker.group,
                            customEndPosition: savedMarker.customEndPosition
                        )
                    },
                    transientMarkers: Set(savedData.transientMarkers),
                    tempSelection: savedData.tempSelection.map { $0.lowerBound...$0.upperBound },
                    pendingGroupAssignment: savedData.pendingGroupAssignment.map { $0.lowerBound...$0.upperBound },
                    hasDetectedTransients: savedData.hasDetectedTransients
                )
                audioViewModel.zoneDataStorage[uuid] = zoneData
            }
        }
        
        // Restore view state
        audioViewModel.zoomLevel = project.zoomLevel
        audioViewModel.scrollOffset = project.scrollOffset
        audioViewModel.yScale = project.yScale
        audioViewModel.showTransientMarkers = project.showTransientMarkers
        audioViewModel.showRegionHighlights = project.showRegionHighlights
        
        // Restore multi sample parts
        samplerViewModel.multiSampleParts = project.multiSampleParts.compactMap { savedPart in
            // Try to resolve source file bookmark
            var sourceURL: URL
            if let bookmarkData = savedPart.sourceFileBookmark {
                do {
                    var isStale = false
                    sourceURL = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
                } catch {
                    // Fall back to path
                    sourceURL = URL(fileURLWithPath: savedPart.sourceFilePath)
                }
            } else {
                sourceURL = URL(fileURLWithPath: savedPart.sourceFilePath)
            }
            
            let velocityRange = VelocityRangeData(
                min: savedPart.velocityRangeMin,
                max: savedPart.velocityRangeMax,
                crossfadeMin: savedPart.velocityCrossfadeMin,
                crossfadeMax: savedPart.velocityCrossfadeMax
            )
            
            var part = MultiSamplePartData(
                name: savedPart.name,
                keyRangeMin: savedPart.keyRangeMin,
                keyRangeMax: savedPart.keyRangeMax,
                velocityRange: velocityRange,
                sourceFileURL: sourceURL,
                segmentStartSample: savedPart.segmentStartSample,
                segmentEndSample: savedPart.segmentEndSample,
                relativePath: savedPart.relativePath,
                absolutePath: savedPart.absolutePath,
                originalAbsolutePath: savedPart.originalAbsolutePath,
                sampleRate: savedPart.sampleRate,
                fileSize: savedPart.fileSize,
                crc: savedPart.crc,
                lastModDate: savedPart.lastModDate,
                originalFileFrameCount: savedPart.originalFileFrameCount
            )
            
            part.isPitched = savedPart.isPitched
            part.originalRootKey = savedPart.originalRootKey
            part.detune = savedPart.detune
            part.tuneScale = savedPart.tuneScale
            part.panorama = savedPart.panorama
            part.volume = savedPart.volume
            part.link = savedPart.link
            part.sustainLoopStart = savedPart.sustainLoopStart
            part.sustainLoopEnd = savedPart.sustainLoopEnd
            part.sustainLoopMode = savedPart.sustainLoopMode
            part.sustainLoopCrossfade = savedPart.sustainLoopCrossfade
            part.sustainLoopDetune = savedPart.sustainLoopDetune
            part.releaseLoopStart = savedPart.releaseLoopStart
            part.releaseLoopEnd = savedPart.releaseLoopEnd
            part.releaseLoopMode = savedPart.releaseLoopMode
            part.releaseLoopCrossfade = savedPart.releaseLoopCrossfade
            part.releaseLoopDetune = savedPart.releaseLoopDetune
            
            return part
        }
        
        // Restore sampler settings
        samplerViewModel.currentMappingMode = MappingMode(rawValue: project.currentMappingMode) ?? .standard
        samplerViewModel.masterEnvelopeAttack = project.masterEnvelopeAttack
        samplerViewModel.masterEnvelopeDecay = project.masterEnvelopeDecay
        samplerViewModel.masterEnvelopeSustain = project.masterEnvelopeSustain
        samplerViewModel.masterEnvelopeRelease = project.masterEnvelopeRelease
        
        currentProjectURL = url
        hasUnsavedChanges = false
    }
}

// MARK: - MappingMode Extension

extension MappingMode: RawRepresentable {
    public var rawValue: String {
        switch self {
        case .standard:
            return "standard"
        case .roundRobin:
            return "roundRobin"
        case .multipleKeys:
            return "multipleKeys"
        }
    }
    
    public init?(rawValue: String) {
        switch rawValue {
        case "standard":
            self = .standard
        case "roundRobin":
            self = .roundRobin
        case "multipleKeys":
            self = .multipleKeys
        default:
            return nil
        }
    }
}