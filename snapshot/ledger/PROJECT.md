# AbletonSampler

> Programmatic Ableton Live sampler instrument builder for iOS/macOS.

## Overview

AbletonSampler parses and creates gzipped XML ADG/ADV files for Ableton Live. It builds sampler instruments from audio files (particularly field recordings) using automated analysis: transient detection, velocity zone splitting, round robin assignment, and spectral grouping. The app imports audio, analyses it, lets the user configure mapping, and exports Ableton-compatible preset files.

**Platform:** iOS / macOS (Xcode project)
**Language:** Swift (SwiftUI)
**Dependencies:** AudioKit (via SPM)
**File Formats:** ADG (instrument rack), ADV (sampler preset) — gzipped XML

## Architecture

### Code Organisation

```
AbletonTest/
  ContentView.swift              — Main UI
  EnhancedContentView.swift      — Extended UI
  Models.swift                   — Data models
  SamplerViewModel.swift         — Core logic / state management
  AudioKitExtensions.swift       — AudioKit integration
  SampleSimilarity.swift         — Spectral analysis / sample grouping
  ImprovedSampleSimilarity.swift — Enhanced similarity detection
  FileNameParser.swift           — Parse sample metadata from filenames
  MIDIManager.swift              — MIDI I/O
  ProjectFile.swift              — Project persistence
  ExportXMLView.swift            — ADV/ADG XML generation and export
  BatchImportView.swift          — Bulk audio import
  GroupToVelocityMapperView.swift — Velocity zone mapping UI
  AmplitudeGroupSuggestionView.swift — Amplitude-based grouping
  PianoKeyboardView.swift        — Visual keyboard for zone editing
  DebugView.swift                — Debug utilities
  OrangeButtonStyle.swift        — Custom styling

Templates:
  ADGTemplate.xml                — Instrument rack XML template
  ADGInstrumentRackTemplate.xml  — Rack variant template
  ADVTemplate.xml                — Sampler preset XML template

Packages:
  Waveform/                      — SPM package for waveform display
```

## Key Concepts

- **ADV files**: Ableton sampler presets. Gzipped XML with sample references using relative paths (`Samples/Imported/`)
- **ADG files**: Ableton instrument racks containing multiple samplers
- **Spectral grouping**: Analyses frequency content to group similar samples together
- **Velocity zones**: Maps sample groups across MIDI velocity ranges
- **Round robin**: Assigns multiple samples to the same note/velocity for variation

## Subsystems

| Subsystem | Status | Document |
|-----------|--------|----------|
| Audio Analysis | Exists | — |
| XML Export | Exists | — |
| Sample Management | Exists | — |

## Phase

**Stalled / returning soon.** Core functionality exists and works. Returning for refinement.

## Linked Projects

| Project | Relationship | Notes |
|---------|-------------|-------|
| — | — | — |

## Open Questions

- Current state of AudioKit compatibility
- Which features work end-to-end vs partially implemented
- Whether to target macOS-only or keep iOS support

**Lane:** personal
