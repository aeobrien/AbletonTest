import Foundation

// MARK: - Marker Model

/// A single marker anchored to a sample position in the audio file
struct Marker: Identifiable, Hashable {
    let id = UUID()
    var samplePosition: Int          // Exact sample index in the original file
    var group: Int? = nil            // Optional group number, assigned via drag-selection
    var customEndPosition: Int? = nil // Optional custom end position (overrides auto-detection)
}

// MARK: - Sample and Velocity Layer Models

/// Represents a velocity zone within a key map
struct VelocityLayer: Identifiable, Hashable {
    let id = UUID()
    var velocityRange: VelocityRangeData
    var samples: [MultiSamplePartData?] // Array for round robins, nil means empty slot
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: VelocityLayer, rhs: VelocityLayer) -> Bool {
        lhs.id == rhs.id
    }
    
    var activeSampleCount: Int {
        samples.compactMap { $0 }.count
    }
    
    var roundRobinCount: Int {
        samples.count
    }
    
    var isEmpty: Bool {
        return activeSampleCount == 0
    }
}

/// Represents the calculated velocity range for a sample part
struct VelocityRangeData: Hashable {
    let min: Int
    let max: Int
    let crossfadeMin: Int
    let crossfadeMax: Int
    
    static let fullRange = VelocityRangeData(min: 0, max: 127, crossfadeMin: 0, crossfadeMax: 127)
}

/// Represents the data needed to generate one <MultiSamplePart> XML element
struct MultiSamplePartData: Identifiable, Hashable {
    static func == (lhs: MultiSamplePartData, rhs: MultiSamplePartData) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    let id = UUID()
    var name: String
    var keyRangeMin: Int // MIDI note number
    var keyRangeMax: Int // MIDI note number (same as min for single key mapping)
    var velocityRange: VelocityRangeData
    let sourceFileURL: URL // Original URL of the audio file containing the segment
    var segmentStartSample: Int64 // Start frame within the source file
    var segmentEndSample: Int64 // End frame (exclusive) within the source file
    
    // Path Information (refers to the source file)
    var relativePath: String? // Path relative to the 'Samples/Imported' directory
    var absolutePath: String // Absolute path of the source file on the user's system
    var originalAbsolutePath: String // Absolute path of the source file before copying
    
    // Extracted metadata
    var sampleRate: Double?
    var fileSize: Int64?
    var crc: UInt32?
    var lastModDate: Date?
    var originalFileFrameCount: Int64?
    
    // Pitched mode properties
    var isPitched: Bool = false  // When true, sample is pitched across key range
    var originalRootKey: Int?    // The original pitch of the sample (for pitched mode)
    
    // Calculated Segment Properties
    var segmentFrameCount: Int64 {
        max(0, segmentEndSample - segmentStartSample)
    }
    
    // Default values for XML fields
    var rootKey: Int { 
        // If pitched mode and original root key is set, use that
        // Otherwise use keyRangeMin (non-pitched behavior)
        originalRootKey ?? keyRangeMin 
    }
    var detune: Int = 0
    var tuneScale: Int = 100
    var panorama: Int = 0
    var volume: Double = 1.0
    var link: Bool = false
    var sampleStart: Int64 { segmentStartSample }
    var sampleEnd: Int64 { segmentEndSample }
    
    // Loop Point Properties
    var sustainLoopStart: Int64? = nil
    var sustainLoopEnd: Int64? = nil
    var sustainLoopMode: Int = 0 // 0=Off, 1=Forward, 2=Forward-Backward
    var sustainLoopCrossfade: Double = 0.0
    var sustainLoopDetune: Double = 0.0
    
    var releaseLoopStart: Int64? = nil
    var releaseLoopEnd: Int64? = nil
    var releaseLoopMode: Int = 3 // 3=Off (default for release)
    var releaseLoopCrossfade: Double = 0.0
    var releaseLoopDetune: Double = 0.0
}

// MARK: - Piano Key Model

/// Represents a single key on the piano
struct PianoKey: Identifiable {
    let id: Int // MIDI Note Number (0-127)
    let isWhite: Bool
    let name: String // e.g., "C4", "F#3", "A0"
    var hasSample: Bool // Indicates if a sample is mapped to this key
    
    // Geometry Properties
    var width: CGFloat = 0
    var height: CGFloat = 0
    var xOffset: CGFloat = 0
    var zIndex: Double = 0
}

// Generates the 128 keys for the full MIDI range
func generatePianoKeys() -> [PianoKey] {
    var keys: [PianoKey] = []
    let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    
    let whiteKeyWidth: CGFloat = 15  // Halved from 30
    let blackKeyWidth: CGFloat = 9   // Halved from 18
    let whiteKeyHeight: CGFloat = 75  // Halved from 150
    let blackKeyHeight: CGFloat = whiteKeyHeight * 0.6
    
    // Generate Key Data
    for midiNote in 0...127 {
        let keyIndexInOctave = midiNote % 12
        let noteName = noteNames[keyIndexInOctave]
        let actualOctave = (midiNote / 12) - 2
        let isWhite: Bool
        switch keyIndexInOctave {
            case 1, 3, 6, 8, 10: isWhite = false
            default: isWhite = true
        }
        let keyName = "\(noteName)\(actualOctave)"
        let key = PianoKey(id: midiNote, isWhite: isWhite, name: keyName, hasSample: false)
        keys.append(key)
    }
    
    // Calculate Layout
    var currentXOffset: CGFloat = 0
    var lastWhiteKeyIndex: Int? = nil
    
    for i in 0..<keys.count {
        if keys[i].isWhite {
            keys[i].width = whiteKeyWidth
            keys[i].height = whiteKeyHeight
            keys[i].xOffset = currentXOffset
            keys[i].zIndex = 0
            currentXOffset += whiteKeyWidth
            lastWhiteKeyIndex = i
        } else { // Black key
            keys[i].width = blackKeyWidth
            keys[i].height = blackKeyHeight
            keys[i].zIndex = 1
            if let lwki = lastWhiteKeyIndex {
                keys[i].xOffset = keys[lwki].xOffset + keys[lwki].width * 0.6
            } else {
                keys[i].xOffset = blackKeyWidth * 0.5
            }
        }
    }
    return keys
}

// MARK: - Supporting Types

struct SelectedSlot: Hashable, Equatable {
    let layerId: VelocityLayer.ID
    let rrIndex: Int
}

enum VelocitySplitMode {
    case separate // Distinct zones, no overlap in core range
    case crossfade // Overlapping zones with crossfades
}

enum MappingMode {
    case standard // Default, one sample per trigger
    case roundRobin // Cycle through samples mapped to the same note
    case multipleKeys // Each group maps to a single key, round robin within that group
}

// MARK: - Transient Group Integration

/// Represents a group of transient markers that can be mapped to a velocity layer
struct TransientGroup: Identifiable {
    let id: Int
    var markers: [Marker]
    var name: String {
        "Group \(id)"
    }
    
    var sampleCount: Int {
        markers.count
    }
}

// MARK: - Zone Models

/// Represents a zone (region) of audio within a file
struct AudioZone: Identifiable {
    let id = UUID()
    var startSample: Int
    var endSample: Int
    var name: String
    var isIgnored: Bool = false
    
    var duration: Int {
        endSample - startSample
    }
}