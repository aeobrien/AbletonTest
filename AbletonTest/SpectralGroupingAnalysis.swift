import Foundation
import AVFoundation

// MARK: - Test Data Models

struct GroupingTestSession: Codable {
    let id = UUID()
    let date = Date()
    let windowLengthMs: Double
    let sampleCount: Int
    let samples: [SampleAnalysisData]
    let manualGrouping: [Int: [String]] // Group number to sample IDs
    let automaticGrouping: [Int: [String]] // Group number to sample IDs
    let comparisonMetrics: ComparisonMetrics?
}

struct SampleAnalysisData: Codable {
    let id: String
    let index: Int
    let name: String
    let samplePosition: Int
    let duration: Double
    
    // Raw features
    let rms: Float
    let spectralCentroidHz: Float
    let spectralRolloffHz: Float
    let spectralBandwidthHz: Float
    let spectralFlatness: Float
    let zeroCrossingRate: Float
    
    // Normalized features
    let normalizedTimbreVector: [Float]
    
    // Clustering info
    let assignedCluster: Int?
    let distanceToClusterCenter: Float?
    let nearestNeighborDistance: Float?
}

struct ClassMetrics: Codable {
    let precision: Float
    let recall: Float
    let f1: Float
}

struct ComparisonMetrics: Codable {
    // Label-invariant headline scores
    let adjustedRandIndex: Float
    let normalizedMutualInfo: Float
    let purityScore: Float
    let silhouetteScore: Float
    
    // New diagnostics (optional to preserve older JSONs)
    let mappedAccuracy: Float?
    let vMeasure: Float?
    let homogeneity: Float?
    let completeness: Float?
    let b3Precision: Float?
    let b3Recall: Float?
    let b3F1: Float?
    let daviesBouldin: Float?
    let calinskiHarabasz: Float?
    let oneToOneAccuracy: Float?
    let accuracyGap: Float?  // many-to-one minus one-to-one
    
    // Confusion + coverage context
    let manualClusterCount: Int?
    let autoClusterCount: Int?
    let samplesScored: Int?
    let totalSamples: Int?
    let coverage: Float?
    let confusionMatrix: [[Int]]?
    let labelMapping: [Int: Int]?    // optimal manual→auto label mapping
    let perClassPRF1: [Int: ClassMetrics]?
    let silhouetteByAutoCluster: [Int: Float]?    // mean s per auto cluster
    let silhouetteByManualGroup: [Int: Float]?    // mean s per manual class
    
    // Merge/split audit
    let merges: [String]?      // e.g., "Manual {1,2} → Auto 0"
    let splits: [String]?      // e.g., "Manual 4 → Auto {2,3}"
    
    let detailedComparison: [SampleComparison]
}

struct SampleComparison: Codable {
    let sampleId: String
    let manualGroup: Int
    let autoGroup: Int
    
    // Agreement after label mapping. Keep the old boolean for UI.
    let agreement: Bool
    
    // New (optional) fields
    let mappedAutoGroup: Int?           // auto label mapped onto manual space
    let distanceToAutoCentroid: Float?  // distance to assigned auto cluster centroid
    let distanceToManualCentroid: Float? // distance to manual group centroid
    let nearestAutoCluster: Int?        // nearest auto cluster (may differ from assigned)
    let secondNearestAutoCluster: Int?  // second nearest auto cluster
    let margin: Float?                  // d2/d1 ratio (ambiguity measure)
}

// MARK: - Analysis Functions

class SpectralGroupingAnalyzer {
    
    // Store the last analysis for comparison
    private var lastFeatureAnalysis: [String: (features: SampleFeatures, normalized: SampleFeatures)] = [:]
    private var lastClusteringInfo: [String: (cluster: Int, distance: Float)] = [:]
    
    /// Perform detailed analysis on samples and return all feature data
    @MainActor
    func analyzeSamples(
        markers: [Marker],
        audioViewModel: EnhancedAudioViewModel,
        windowMs: Double = 256
    ) -> [SampleAnalysisData] {
        
        var analysisResults: [SampleAnalysisData] = []
        
        guard let buffer = audioViewModel.sampleBuffer else { 
            print("No sample buffer available")
            return [] 
        }
        let sortedMarkers = markers.sorted { $0.samplePosition < $1.samplePosition }
        print("Analyzing \(sortedMarkers.count) markers...")
        
        // First pass: extract all features
        var allFeatures: [(marker: Marker, features: SampleFeatures, url: URL)] = []
        let tempDir = FileManager.default.temporaryDirectory
        
        for (index, marker) in sortedMarkers.enumerated() {
            let startPos = marker.samplePosition
            let endPos: Int
            
            if let customEnd = marker.customEndPosition {
                endPos = customEnd
            } else if index < sortedMarkers.count - 1 {
                endPos = sortedMarkers[index + 1].samplePosition
            } else {
                endPos = audioViewModel.zoneStartOffset + audioViewModel.zoneTotalSamples
            }
            
            let regionLength = endPos - startPos
            guard regionLength > 0 else { continue }
            
            // Create temporary WAV file for analysis
            let regionSamples = Array(buffer.samples[startPos..<min(endPos, buffer.samples.count)])
            let tempURL = tempDir.appendingPathComponent("analysis_\(marker.id.uuidString).wav")
            
            guard regionSamples.count > 0 else {
                print("Warning: Empty region for marker \(marker.id)")
                continue
            }
            
            print("Processing marker \(index+1)/\(sortedMarkers.count): \(regionSamples.count) samples")
            
            // Write audio file in a separate scope to ensure it's closed
            do {
                try autoreleasepool {
                    let audioFile = try AVAudioFile(forWriting: tempURL, settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: audioViewModel.sampleRate,
                        AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsNonInterleaved: false
                    ])
                    
                    let format = audioFile.processingFormat
                    guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(regionSamples.count)) else {
                        throw NSError(domain: "SpectralAnalysis", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
                    }
                    
                    audioBuffer.frameLength = AVAudioFrameCount(regionSamples.count)
                    
                    guard let channelData = audioBuffer.floatChannelData else {
                        throw NSError(domain: "SpectralAnalysis", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to get channel data"])
                    }
                    
                    for (i, sample) in regionSamples.enumerated() {
                        channelData[0][i] = sample
                    }
                    
                    try audioFile.write(from: audioBuffer)
                }
                
                // Verify file was written
                let fileAttributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
                let fileSize = fileAttributes[.size] as? Int64 ?? 0
                print("Created audio file: \(tempURL.lastPathComponent), size: \(fileSize) bytes")
                
                // Now read and extract features
                let features = try extractFeatures(from: tempURL, windowMs: windowMs)
                allFeatures.append((marker: marker, features: features, url: tempURL))
                lastFeatureAnalysis[marker.id.uuidString] = (features: features, normalized: features)
                
            } catch {
                print("Failed to process marker \(marker.id): \(error)")
            }
        }
        
        print("Extracted features for \(allFeatures.count) samples")
        
        // Second pass: normalize features
        let normalizedFeatures = zScoreNormalize(features: allFeatures.map { $0.features })
        
        // Store normalized features
        for (index, item) in allFeatures.enumerated() {
            lastFeatureAnalysis[item.marker.id.uuidString]?.normalized = normalizedFeatures[index]
        }
        
        // Third pass: create analysis data
        for (index, item) in allFeatures.enumerated() {
            let marker = item.marker
            let features = item.features
            let normalized = normalizedFeatures[index]
            
            let markerIndex = sortedMarkers.firstIndex(where: { $0.id == marker.id }) ?? index
            
            let analysis = SampleAnalysisData(
                id: marker.id.uuidString,
                index: markerIndex,
                name: "Region \(markerIndex + 1)",
                samplePosition: marker.samplePosition,
                duration: Double(item.features.rms > 0 ? 1000 : 0), // Placeholder duration
                rms: features.rms,
                spectralCentroidHz: features.spectralCentroidHz,
                spectralRolloffHz: features.spectralRolloffHz,
                spectralBandwidthHz: features.spectralBandwidthHz,
                spectralFlatness: features.spectralFlatness,
                zeroCrossingRate: features.zeroCrossingRate,
                normalizedTimbreVector: normalized.timbreVector,
                assignedCluster: nil,
                distanceToClusterCenter: nil,
                nearestNeighborDistance: nil
            )
            
            analysisResults.append(analysis)
        }
        
        // Clean up temp files
        for item in allFeatures {
            try? FileManager.default.removeItem(at: item.url)
        }
        
        return analysisResults
    }
    
    /// Run the automatic grouping algorithm and capture detailed clustering info
    @MainActor
    func runAutomaticGrouping(
        markers: [Marker],
        audioViewModel: EnhancedAudioViewModel,
        windowMs: Double = 256
    ) -> (grouping: [Int: [String]], analysisData: [SampleAnalysisData]) {
        
        var analysisResults = analyzeSamples(markers: markers, audioViewModel: audioViewModel, windowMs: windowMs)
        
        // Create URLs for the grouping algorithm
        let tempDir = FileManager.default.temporaryDirectory
        var markerToURL: [String: URL] = [:]
        
        guard let buffer = audioViewModel.sampleBuffer else { return ([:], analysisResults) }
        let sortedMarkers = markers.sorted { $0.samplePosition < $1.samplePosition }
        
        // Create temp files
        for (index, marker) in sortedMarkers.enumerated() {
            let startPos = marker.samplePosition
            let endPos: Int
            
            if let customEnd = marker.customEndPosition {
                endPos = customEnd
            } else if index < sortedMarkers.count - 1 {
                endPos = sortedMarkers[index + 1].samplePosition
            } else {
                endPos = audioViewModel.zoneStartOffset + audioViewModel.zoneTotalSamples
            }
            
            let regionSamples = Array(buffer.samples[startPos..<min(endPos, buffer.samples.count)])
            let tempURL = tempDir.appendingPathComponent("group_\(marker.id.uuidString).wav")
            
            do {
                guard regionSamples.count > 0 else {
                    print("Warning: Empty region for marker \(marker.id) in runAutomaticGrouping")
                    continue
                }
                
                let audioFile = try AVAudioFile(forWriting: tempURL, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: audioViewModel.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false
                ])
                
                let format = audioFile.processingFormat
                guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(regionSamples.count)) else {
                    print("Failed to create audio buffer for marker \(marker.id) in runAutomaticGrouping")
                    continue
                }
                
                audioBuffer.frameLength = AVAudioFrameCount(regionSamples.count)
                
                if let channelData = audioBuffer.floatChannelData {
                    for (i, sample) in regionSamples.enumerated() {
                        channelData[0][i] = sample
                    }
                    
                    try audioFile.write(from: audioBuffer)
                    markerToURL[marker.id.uuidString] = tempURL
                } else {
                    print("Failed to get channel data for marker \(marker.id) in runAutomaticGrouping")
                }
            } catch {
                print("Failed to create audio file for marker \(marker.id): \(error)")
            }
        }
        
        // Run automatic grouping
        let urls = sortedMarkers.compactMap { markerToURL[$0.id.uuidString] }
        
        if let groups = try? autoGroupSamplesIntoPseudoVelocityLayers(urls: urls, windowMs: windowMs) {
            var grouping: [Int: [String]] = [:]
            
            // Convert URL groups back to marker IDs
            for (groupIndex, groupURLs) in groups.enumerated() {
                grouping[groupIndex] = []
                for url in groupURLs {
                    if let entry = markerToURL.first(where: { $0.value == url }) {
                        grouping[groupIndex]?.append(entry.key)
                        
                        // Update analysis data with cluster assignment
                        if let idx = analysisResults.firstIndex(where: { $0.id == entry.key }) {
                            var updated = analysisResults[idx]
                            analysisResults[idx] = SampleAnalysisData(
                                id: updated.id,
                                index: updated.index,
                                name: updated.name,
                                samplePosition: updated.samplePosition,
                                duration: updated.duration,
                                rms: updated.rms,
                                spectralCentroidHz: updated.spectralCentroidHz,
                                spectralRolloffHz: updated.spectralRolloffHz,
                                spectralBandwidthHz: updated.spectralBandwidthHz,
                                spectralFlatness: updated.spectralFlatness,
                                zeroCrossingRate: updated.zeroCrossingRate,
                                normalizedTimbreVector: updated.normalizedTimbreVector,
                                assignedCluster: groupIndex,
                                distanceToClusterCenter: lastClusteringInfo[entry.key]?.distance,
                                nearestNeighborDistance: nil
                            )
                        }
                    }
                }
            }
            
            // Clean up temp files
            for url in markerToURL.values {
                try? FileManager.default.removeItem(at: url)
            }
            
            return (grouping, analysisResults)
        }
        
        // Clean up on failure
        for url in markerToURL.values {
            try? FileManager.default.removeItem(at: url)
        }
        
        return ([:], analysisResults)
    }
    
    /// Compare manual and automatic groupings
    func compareGroupings(
        manual: [Int: [String]],
        automatic: [Int: [String]],
        analysisData: [SampleAnalysisData]
    ) -> ComparisonMetrics {
        
        // Create reverse mappings
        var manualSampleToGroup: [String: Int] = [:]
        var autoSampleToGroup: [String: Int] = [:]
        
        for (group, samples) in manual {
            for sample in samples {
                manualSampleToGroup[sample] = group
            }
        }
        
        for (group, samples) in automatic {
            for sample in samples {
                autoSampleToGroup[sample] = group
            }
        }
        
        // Get contingency table and related data
        let (tab, rows, cols, n, mLabels, aLabels) = contingency(manual: manualSampleToGroup, auto: autoSampleToGroup)
        
        // Calculate main metrics
        let ari = calculateAdjustedRandIndex(manual: manualSampleToGroup, auto: autoSampleToGroup)
        let nmi = calculateNormalizedMutualInfo(manual: manualSampleToGroup, auto: autoSampleToGroup)
        let purity = calculatePurity(manual: manualSampleToGroup, auto: autoSampleToGroup)
        
        // Calculate silhouette scores
        let (silhouetteGlobal, silhouetteByAuto) = silhouetteScores(analysisData: analysisData, grouping: autoSampleToGroup)
        let (_, silhouetteByManual) = silhouetteScores(analysisData: analysisData, grouping: manualSampleToGroup)
        
        // Calculate homogeneity, completeness, V-measure
        let (homo, comp, vMeasure) = homogeneityCompletenessV(tab: tab, rows: rows, cols: cols, n: n)
        
        // Calculate B³ scores
        let (b3Prec, b3Rec, b3F1) = b3Scores(manual: manualSampleToGroup, auto: autoSampleToGroup)
        
        // Get optimal label mapping (many-to-one)
        let labelMap = majorityMapping(tab: tab, mLabels: mLabels, aLabels: aLabels)
        
        // Calculate mapped accuracy
        let mappedAcc = mappedAccuracy(tab: tab, rows: rows, mLabels: mLabels, aLabels: aLabels)
        
        // Get confusion matrix
        let confusionMatrix = buildConfusionMatrix(tab: tab)
        
        // Per-class metrics from confusion matrix
        let perClass = perClassPRF1FromConfusion(tab: tab, rows: rows, cols: cols, 
                                                  mLabels: mLabels, aLabels: aLabels)
        
        // Find merges and splits
        let (merges, splits) = findMergesAndSplits(tab: tab, mLabels: mLabels, aLabels: aLabels)
        
        // Calculate centroids
        let autoCentroids = centroids(for: autoSampleToGroup, data: analysisData)
        let manualCentroids = centroids(for: manualSampleToGroup, data: analysisData)
        
        // Calculate new clustering quality indices
        let X = analysisData.filter { !$0.normalizedTimbreVector.isEmpty }.map { $0.normalizedTimbreVector }
        let y = analysisData.filter { !$0.normalizedTimbreVector.isEmpty }.compactMap { autoSampleToGroup[$0.id] }
        
        let dbi = X.isEmpty ? nil : daviesBouldin(X: X, y: y)
        let ch = X.isEmpty ? nil : calinskiHarabasz(X: X, y: y)
        
        // Calculate one-to-one accuracy and gap
        let oneToOne = oneToOneAccuracy(tab: tab, rows: rows, mLabels: mLabels, aLabels: aLabels)
        let accGap = mappedAcc - oneToOne
        
        // Calculate sample ambiguity
        let ambiguityInfo = calculateSampleAmbiguity(X: X, y: y, centroids: autoCentroids)
        
        // Create detailed comparison with mapped groups and distances
        var comparisons: [SampleComparison] = []
        var ambiguityIndex = 0
        for data in analysisData {
            let manualGroup = manualSampleToGroup[data.id] ?? -1
            let autoGroup = autoSampleToGroup[data.id] ?? -1
            
            // Check agreement: does manual group map to this auto group?
            let agreement = manualGroup >= 0 && labelMap[manualGroup] == autoGroup
            
            // Calculate distances to centroids
            var distToAuto: Float? = nil
            var distToManual: Float? = nil
            var nearest: Int? = nil
            var secondNearest: Int? = nil
            var margin: Float? = nil
            
            if !data.normalizedTimbreVector.isEmpty {
                if let autoCent = autoCentroids[autoGroup] {
                    distToAuto = euclid(data.normalizedTimbreVector, autoCent)
                }
                if let manualCent = manualCentroids[manualGroup] {
                    distToManual = euclid(data.normalizedTimbreVector, manualCent)
                }
                
                // Get ambiguity info
                if ambiguityIndex < ambiguityInfo.count {
                    let info = ambiguityInfo[ambiguityIndex]
                    nearest = info.nearest
                    secondNearest = info.secondNearest
                    margin = info.margin
                    ambiguityIndex += 1
                }
            }
            
            comparisons.append(SampleComparison(
                sampleId: data.id,
                manualGroup: manualGroup,
                autoGroup: autoGroup,
                agreement: agreement,
                mappedAutoGroup: labelMap[manualGroup],
                distanceToAutoCentroid: distToAuto,
                distanceToManualCentroid: distToManual,
                nearestAutoCluster: nearest,
                secondNearestAutoCluster: secondNearest,
                margin: margin
            ))
        }
        
        // Calculate coverage
        let allSamples = Set(manualSampleToGroup.keys).union(Set(autoSampleToGroup.keys))
        let scoredSamples = Set(manualSampleToGroup.keys).intersection(Set(autoSampleToGroup.keys))
        let coverage = Float(scoredSamples.count) / Float(max(allSamples.count, 1))
        
        return ComparisonMetrics(
            adjustedRandIndex: ari,
            normalizedMutualInfo: nmi,
            purityScore: purity,
            silhouetteScore: silhouetteGlobal,
            mappedAccuracy: mappedAcc,
            vMeasure: vMeasure,
            homogeneity: homo,
            completeness: comp,
            b3Precision: b3Prec,
            b3Recall: b3Rec,
            b3F1: b3F1,
            daviesBouldin: dbi,
            calinskiHarabasz: ch,
            oneToOneAccuracy: oneToOne,
            accuracyGap: accGap,
            manualClusterCount: Set(manualSampleToGroup.values).count,
            autoClusterCount: Set(autoSampleToGroup.values).count,
            samplesScored: scoredSamples.count,
            totalSamples: allSamples.count,
            coverage: coverage,
            confusionMatrix: confusionMatrix,
            labelMapping: labelMap.isEmpty ? nil : labelMap,
            perClassPRF1: perClass,
            silhouetteByAutoCluster: silhouetteByAuto,
            silhouetteByManualGroup: silhouetteByManual,
            merges: merges.isEmpty ? nil : merges,
            splits: splits.isEmpty ? nil : splits,
            detailedComparison: comparisons
        )
    }
    
    /// Export analysis to JSON file
    func exportAnalysis(
        session: GroupingTestSession,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        let data = try encoder.encode(session)
        try data.write(to: url)
    }
    
    /// Print detailed analysis to console
    func printDetailedAnalysis(_ session: GroupingTestSession) {
        print("\n" + String(repeating: "=", count: 80))
        print("SPECTRAL GROUPING ANALYSIS REPORT")
        print("Session ID: \(session.id)")
        print("Date: \(session.date)")
        print("Sample Count: \(session.sampleCount)")
        print("Window Length: \(session.windowLengthMs)ms")
        print(String(repeating: "=", count: 80))
        
        if let metrics = session.comparisonMetrics {
            // Summary metrics
            print("\nSUMMARY:")
            print(String(repeating: "-", count: 60))
            print("K_manual: \(metrics.manualClusterCount ?? session.manualGrouping.count)  K_auto: \(metrics.autoClusterCount ?? session.automaticGrouping.count)")
            print("Coverage: \(String(format: "%.1f%%", (metrics.coverage ?? 1.0) * 100))  (\(metrics.samplesScored ?? session.sampleCount)/\(metrics.totalSamples ?? session.sampleCount) samples)")
            
            // Headline metrics
            print("\nHEADLINE METRICS:")
            print(String(repeating: "-", count: 80))
            
            // Show mapped accuracy if available
            if let mappedAcc = metrics.mappedAccuracy {
                print(String(format: "ACC (mapped): %.3f", mappedAcc), terminator: "  ")
            }
            
            print(String(format: "ARI: %.3f", metrics.adjustedRandIndex), terminator: "  ")
            print(String(format: "NMI: %.3f", metrics.normalizedMutualInfo), terminator: "  ")
            
            if let vMeasure = metrics.vMeasure {
                print(String(format: "V-measure: %.3f", vMeasure), terminator: "  ")
            }
            
            print(String(format: "Purity: %.3f", metrics.purityScore), terminator: "  ")
            print(String(format: "Sil: %.3f", metrics.silhouetteScore))
            
            // Clustering quality indices
            if let dbi = metrics.daviesBouldin {
                print(String(format: "DBI: %.3f", dbi), terminator: "  ")
            }
            if let ch = metrics.calinskiHarabasz {
                print(String(format: "CH: %.1f", ch), terminator: "  ")
            }
            
            // Accuracy comparison
            if let oneToOne = metrics.oneToOneAccuracy, let gap = metrics.accuracyGap {
                print(String(format: "\nACC_1to1: %.3f  ACC_gap: %.3f", oneToOne, gap), terminator: "")
                if gap > 0.1 {
                    print(" (merge signal)")
                } else {
                    print("")
                }
            }
            
            // Additional metrics if available
            if let homo = metrics.homogeneity, let comp = metrics.completeness,
               let b3P = metrics.b3Precision, let b3R = metrics.b3Recall, let b3F = metrics.b3F1 {
                print(String(format: "Homogeneity: %.3f  Completeness: %.3f", homo, comp))
                print(String(format: "B³ (P/R/F1): %.3f/%.3f/%.3f", b3P, b3R, b3F))
            }
            
            // Per-cluster silhouette scores with warnings
            if let autoSilhouettes = metrics.silhouetteByAutoCluster {
                print("\nPER-CLUSTER SILHOUETTES (auto):")
                print(String(repeating: "-", count: 40))
                for (cluster, score) in autoSilhouettes.sorted(by: { $0.key < $1.key }) {
                    let warning = score < 0.2 ? " ⚠️ (boundary cluster)" : ""
                    print(String(format: "Cluster %d: %.3f%@", cluster, score, warning))
                }
                
                // Add suggestions for low silhouette clusters
                let lowSilhouetteClusters = autoSilhouettes.filter { $0.value < 0.2 }
                if !lowSilhouetteClusters.isEmpty {
                    print("\n⚠️  Low silhouette clusters detected. Check feature thresholds for:")
                    for (cluster, _) in lowSilhouetteClusters {
                        // Find which manual groups are in this auto cluster
                        let manualGroups = metrics.detailedComparison
                            .filter { $0.autoGroup == cluster }
                            .map { $0.manualGroup }
                            .removingDuplicates()
                            .sorted()
                        print("   Auto \(cluster) contains Manual groups: \(manualGroups)")
                    }
                }
            }
            
            // Add K mismatch note
            if let kManual = metrics.manualClusterCount, 
               let kAuto = metrics.autoClusterCount {
                if kManual != kAuto {
                    print("\n📊 K mismatch: K_auto=\(kAuto) vs K_manual=\(kManual)")
                    if kAuto < kManual {
                        print("   → Expect merges (multiple manual groups in same auto cluster)")
                    } else {
                        print("   → Expect splits (manual groups distributed across auto clusters)")
                    }
                }
            }
            
            // Confusion matrix (compact)
            if let confusion = metrics.confusionMatrix, !confusion.isEmpty {
                print("\nCONFUSION MATRIX (manual→auto):")
                print(String(repeating: "-", count: 50))
                
                // Get labels from the session
                let manualLabels = Array(Set(session.manualGrouping.keys)).sorted()
                let autoLabels = Array(Set(session.automaticGrouping.keys)).sorted()
                
                // Print header
                print("     ", terminator: "")
                for autoLabel in autoLabels {
                    print(String(format: "%5d", autoLabel), terminator: "")
                }
                print(" | Total")
                print(String(repeating: "-", count: 5 + autoLabels.count * 5 + 8))
                
                // Print rows
                for (i, manualLabel) in manualLabels.enumerated() {
                    print(String(format: "%3d: ", manualLabel), terminator: "")
                    var rowSum = 0
                    if i < confusion.count {
                        for j in 0..<confusion[i].count {
                            print(String(format: "%5d", confusion[i][j]), terminator: "")
                            rowSum += confusion[i][j]
                        }
                    }
                    print(String(format: " | %5d", rowSum))
                }
            }
            
            // Top confusions per manual group
            if let perClass = metrics.perClassPRF1 {
                print("\nTOP CONFUSIONS BY MANUAL GROUP:")
                print(String(repeating: "-", count: 60))
                
                // Analyze confusion matrix to find top 2 confusions per manual group
                if let confusion = metrics.confusionMatrix {
                    let manualLabels = Array(Set(session.manualGrouping.keys)).sorted()
                    let autoLabels = Array(Set(session.automaticGrouping.keys)).sorted()
                    
                    for (i, manualLabel) in manualLabels.enumerated() {
                        if i < confusion.count {
                            let row = confusion[i]
                            // Get top 2 auto clusters for this manual group
                            let sorted = row.enumerated()
                                .sorted { $0.element > $1.element }
                                .prefix(2)
                                .filter { $0.element > 0 }
                            
                            if !sorted.isEmpty {
                                print("Manual \(manualLabel): ", terminator: "")
                                let confusionInfo = sorted.map { (idx, count) in
                                    let autoLabel = idx < autoLabels.count ? autoLabels[idx] : idx
                                    return "→Auto \(autoLabel) (\(count))"
                                }.joined(separator: ", ")
                                
                                if let metrics = perClass[manualLabel] {
                                    print("\(confusionInfo)  [P:\(String(format: "%.2f", metrics.precision)) R:\(String(format: "%.2f", metrics.recall))]")
                                } else {
                                    print(confusionInfo)
                                }
                            }
                        }
                    }
                }
            }
            
            // Merges and splits
            if let merges = metrics.merges, !merges.isEmpty {
                print("\nMERGES (manual groups in same auto cluster):")
                print(String(repeating: "-", count: 50))
                for merge in merges.prefix(5) {  // Show top 5
                    print("• \(merge)")
                }
            }
            
            if let splits = metrics.splits, !splits.isEmpty {
                print("\nSPLITS (manual group across auto clusters):")
                print(String(repeating: "-", count: 50))
                for split in splits.prefix(5) {  // Show top 5
                    print("• \(split)")
                }
            }
            
            // Misclustered samples with centroid distances
            let misclustered = metrics.detailedComparison.filter { !$0.agreement }
            if !misclustered.isEmpty {
                print("\nMISCLUSTERED SAMPLES (with centroid distance deltas):")
                print(String(repeating: "-", count: 80))
                
                for comp in misclustered.prefix(10) {  // Show top 10
                    let sampleName = session.samples.first(where: { $0.id == comp.sampleId })?.name ?? comp.sampleId
                    let paddedName = sampleName.padding(toLength: 20, withPad: " ", startingAt: 0)
                    print("• \(paddedName): Manual \(comp.manualGroup) → Auto \(comp.autoGroup)", terminator: "")
                    
                    if let manualDist = comp.distanceToManualCentroid,
                       let autoDist = comp.distanceToAutoCentroid {
                        let delta = autoDist - manualDist
                        print(String(format: "  (Δ=%.3f)", delta))
                    } else {
                        print("")
                    }
                }
                
                if misclustered.count > 10 {
                    print("... and \(misclustered.count - 10) more")
                }
            }
            
            // Ambiguous samples (low margin)
            let ambiguous = metrics.detailedComparison.filter { 
                $0.margin != nil && $0.margin! < 1.2 
            }
            if !ambiguous.isEmpty {
                print("\n⚠️  AMBIGUOUS SAMPLES (margin < 1.2):")
                print(String(repeating: "-", count: 80))
                
                for comp in ambiguous.prefix(10) {
                    let sampleName = session.samples.first(where: { $0.id == comp.sampleId })?.name ?? comp.sampleId
                    let paddedName = sampleName.padding(toLength: 20, withPad: " ", startingAt: 0)
                    print("• \(paddedName): ", terminator: "")
                    
                    if let nearest = comp.nearestAutoCluster, 
                       let second = comp.secondNearestAutoCluster,
                       let margin = comp.margin {
                        print(String(format: "Nearest A%d, Second A%d (margin=%.2f)", 
                              nearest, second, margin))
                    }
                }
                
                if ambiguous.count > 10 {
                    print("... and \(ambiguous.count - 10) more")
                }
            }
        }
        
        // Feature Analysis Table (shortened)
        print("\n\nFEATURE ANALYSIS (top 10 samples):")
        print(String(repeating: "-", count: 100))
        
        let header = "Sample".padding(toLength: 16, withPad: " ", startingAt: 0) + " " +
                    "RMS".padding(toLength: 8, withPad: " ", startingAt: 0) + " " +
                    "Centroid".padding(toLength: 10, withPad: " ", startingAt: 0) + " " +
                    "Rolloff".padding(toLength: 10, withPad: " ", startingAt: 0) + " " +
                    "Bandwidth".padding(toLength: 10, withPad: " ", startingAt: 0) + " " +
                    "Flatness".padding(toLength: 10, withPad: " ", startingAt: 0) + " " +
                    "M→A".padding(toLength: 7, withPad: " ", startingAt: 0)
        print(header)
        print(String(repeating: "-", count: 100))
        
        for (idx, sample) in session.samples.prefix(10).enumerated() {
            let comp = session.comparisonMetrics?.detailedComparison.first { $0.sampleId == sample.id }
            let mapping = comp != nil ? "\(comp!.manualGroup)→\(comp!.autoGroup)" : "-"
            
            let row = sample.name.padding(toLength: 16, withPad: " ", startingAt: 0) + " " +
                     String(format: "%.4f", sample.rms).padding(toLength: 8, withPad: " ", startingAt: 0) + " " +
                     String(format: "%.0f", sample.spectralCentroidHz).padding(toLength: 10, withPad: " ", startingAt: 0) + " " +
                     String(format: "%.0f", sample.spectralRolloffHz).padding(toLength: 10, withPad: " ", startingAt: 0) + " " +
                     String(format: "%.0f", sample.spectralBandwidthHz).padding(toLength: 10, withPad: " ", startingAt: 0) + " " +
                     String(format: "%.3f", sample.spectralFlatness).padding(toLength: 10, withPad: " ", startingAt: 0) + " " +
                     mapping.padding(toLength: 7, withPad: " ", startingAt: 0)
            print(row)
        }
        
        if session.samples.count > 10 {
            print("... and \(session.samples.count - 10) more samples")
        }
        
        print("\n" + String(repeating: "=", count: 80))
    }
    
    /// Get confusion matrix and optimal label mapping
    private func getConfusionMatrixAndMapping(manual: [String: Int], auto: [String: Int]) -> ([[Int]], [Int: Int]) {
        let (table, _, _, _, mLabels, aLabels) = contingency(manual: manual, auto: auto)
        
        // Find optimal mapping using greedy approach
        var mapping: [Int: Int] = [:]
        let manualLabels = Array(Set(manual.values)).sorted()
        let autoLabels = Array(Set(auto.values)).sorted()
        
        // Create a mutable copy of the confusion matrix
        var workingTable = table
        
        // Greedy mapping: repeatedly find the max value and assign that mapping
        while mapping.count < min(manualLabels.count, autoLabels.count) {
            var maxVal = -1
            var maxRow = -1
            var maxCol = -1
            
            for i in 0..<workingTable.count {
                for j in 0..<workingTable[i].count {
                    if workingTable[i][j] > maxVal {
                        maxVal = workingTable[i][j]
                        maxRow = i
                        maxCol = j
                    }
                }
            }
            
            if maxVal > 0 {
                // Map auto label to manual label
                mapping[autoLabels[maxCol]] = manualLabels[maxRow]
                
                // Zero out the row and column to prevent reuse
                for j in 0..<workingTable[maxRow].count {
                    workingTable[maxRow][j] = 0
                }
                for i in 0..<workingTable.count {
                    workingTable[i][maxCol] = 0
                }
            } else {
                break
            }
        }
        
        return (table, mapping)
    }
    
    // MARK: - Metric Calculations
    
    // Helper: n choose 2
    private func nC2(_ n: Int) -> Int { 
        return n < 2 ? 0 : n * (n - 1) / 2 
    }
    
    // Build contingency table over intersection of labelled samples
    private func contingency(manual: [String: Int], auto: [String: Int]) 
    -> (table: [[Int]], rowSums: [Int], colSums: [Int], n: Int, mLabels: [Int], aLabels: [Int]) {
        let keys = Set(manual.keys).intersection(auto.keys)
        let mLabels = Array(Set(keys.compactMap { manual[$0] })).sorted()
        let aLabels = Array(Set(keys.compactMap { auto[$0] })).sorted()
        var mapM = [Int: Int](), mapA = [Int: Int]()
        for (i, l) in mLabels.enumerated() { mapM[l] = i }
        for (j, l) in aLabels.enumerated() { mapA[l] = j }
        var table = Array(repeating: Array(repeating: 0, count: aLabels.count), count: mLabels.count)
        for k in keys {
            table[mapM[manual[k]!]!][mapA[auto[k]!]!] += 1
        }
        let rowSums = table.map { $0.reduce(0, +) }
        let colSums = (0..<aLabels.count).map { j in table.reduce(0) { $0 + $1[j] } }
        return (table, rowSums, colSums, keys.count, mLabels, aLabels)
    }
    
    private func calculateAdjustedRandIndex(manual: [String: Int], auto: [String: Int]) -> Float {
        let (tab, rows, cols, n, _, _) = contingency(manual: manual, auto: auto)
        guard n > 1 else { return 1.0 }
        let sumComb = tab.flatMap { $0 }.reduce(0) { $0 + nC2($1) }
        let sumRows = rows.reduce(0) { $0 + nC2($1) }
        let sumCols = cols.reduce(0) { $0 + nC2($1) }
        let totalComb = nC2(n)
        let expected = Float(sumRows * sumCols) / Float(max(totalComb, 1))
        let maxTerm = Float(sumRows + sumCols) / 2.0
        let numerator = Float(sumComb) - expected
        let denominator = maxTerm - expected
        return denominator == 0 ? 1.0 : numerator / denominator
    }
    
    private func calculateNormalizedMutualInfo(manual: [String: Int], auto: [String: Int]) -> Float {
        let (tab, rows, cols, n, _, _) = contingency(manual: manual, auto: auto)
        guard n > 0 else { return 0 }
        let nF = Float(n)
        var mi: Float = 0
        for i in tab.indices {
            for j in tab[i].indices {
                let nij = tab[i][j]
                if nij == 0 { continue }
                let nijF = Float(nij)
                let rowF = Float(rows[i])
                let colF = Float(cols[j])
                mi += (nijF / nF) * logf((nijF * nF) / (rowF * colF))
            }
        }
        // Natural log variant; normalise by sqrt(H(U) * H(V))
        let hU = rows.reduce(Float(0)) { acc, count in
            let p = Float(count) / nF
            return acc - (count > 0 ? p * logf(p) : 0)
        }
        let hV = cols.reduce(Float(0)) { acc, count in
            let p = Float(count) / nF
            return acc - (count > 0 ? p * logf(p) : 0)
        }
        let denom = sqrtf(max(hU, 1e-12) * max(hV, 1e-12))
        return denom == 0 ? 0 : mi / denom
    }
    
    private func calculatePurity(manual: [String: Int], auto: [String: Int]) -> Float {
        let keys = Set(manual.keys).intersection(auto.keys)
        guard !keys.isEmpty else { return 0 }
        
        // Build auto clusters from intersection only
        var autoGroups: [Int: [String]] = [:]
        for k in keys {
            if let autoGroup = auto[k] {
                autoGroups[autoGroup, default: []].append(k)
            }
        }
        
        var correct = 0
        for (_, samples) in autoGroups {
            var counts: [Int: Int] = [:]
            for s in samples {
                if let manualGroup = manual[s] {
                    counts[manualGroup, default: 0] += 1
                }
            }
            correct += counts.values.max() ?? 0
        }
        
        return Float(correct) / Float(keys.count)
    }
    
    private func euclid(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        let n = min(a.count, b.count)
        for i in 0..<n { 
            let d = a[i] - b[i]
            s += d * d 
        }
        return sqrtf(s)
    }
    
    private func silhouetteScores(analysisData: [SampleAnalysisData], grouping: [String: Int]) 
    -> (global: Float, byGroup: [Int: Float]) {
        // Pack vectors (only items with vector & group)
        var X: [[Float]] = []
        var y: [Int] = []
        var ids: [String] = []
        for s in analysisData {
            if let g = grouping[s.id], !s.normalizedTimbreVector.isEmpty {
                X.append(s.normalizedTimbreVector)
                y.append(g)
                ids.append(s.id)
            }
        }
        let n = X.count
        guard n > 1 else { return (0, [:]) }
        
        // Distance matrix
        var D = Array(repeating: Array(repeating: Float(0), count: n), count: n)
        for i in 0..<n { 
            for j in i+1..<n { 
                let d = euclid(X[i], X[j])
                D[i][j] = d
                D[j][i] = d 
            } 
        }
        
        // Indices per group
        let groups = Dictionary(grouping: Array(0..<n), by: { y[$0] })
        
        // Silhouette per index
        var sVals = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let gi = y[i]
            // a(i)
            let own = groups[gi] ?? []
            let aCnt = max(own.count - 1, 0)
            let a = aCnt > 0 ? own.filter { $0 != i }.map { D[i][$0] }.reduce(0, +) / Float(aCnt) : 0
            // b(i)
            var b = Float.greatestFiniteMagnitude
            for (g, members) in groups where g != gi && !members.isEmpty {
                let mean = members.map { D[i][$0] }.reduce(0, +) / Float(members.count)
                b = min(b, mean)
            }
            if !b.isFinite { b = 0 }
            let denom = max(a, b)
            sVals[i] = denom > 0 ? (b - a) / denom : 0
        }
        
        let global = sVals.reduce(0, +) / Float(n)
        var by: [Int: Float] = [:]
        for (g, members) in groups {
            let v = members.map { sVals[$0] }
            by[g] = v.isEmpty ? 0 : v.reduce(0, +) / Float(v.count)
        }
        return (global, by)
    }
    
    private func homogeneityCompletenessV(tab: [[Int]], rows: [Int], cols: [Int], n: Int) -> (Float, Float, Float) {
        let nF = Float(n)
        // Entropies
        let hU = rows.reduce(0) { $0 - (Float($1)/nF) * logf(max(Float($1)/nF, 1e-12)) }
        let hV = cols.reduce(0) { $0 - (Float($1)/nF) * logf(max(Float($1)/nF, 1e-12)) }
        // Mutual information (reuse logic)
        var mi: Float = 0
        for i in tab.indices {
            for j in tab[i].indices {
                let nij = tab[i][j]
                if nij == 0 { continue }
                mi += Float(nij)/nF * logf((Float(nij)*nF)/(Float(rows[i])*Float(cols[j])))
            }
        }
        let homo = hU == 0 ? 1 : mi / hU
        let comp = hV == 0 ? 1 : mi / hV
        let v = (homo + comp) == 0 ? 0 : 2 * homo * comp / (homo + comp)
        return (homo, comp, v)
    }
    
    private func b3Scores(manual: [String: Int], auto: [String: Int]) -> (Float, Float, Float) {
        let keys = Array(Set(manual.keys).intersection(auto.keys))
        guard !keys.isEmpty else { return (0, 0, 0) }
        // Build inverted indices
        var manToItems: [Int: Set<String>] = [:]
        var autoToItems: [Int: Set<String>] = [:]
        for k in keys { 
            manToItems[manual[k]!, default: []].insert(k)
            autoToItems[auto[k]!, default: []].insert(k) 
        }
        var pSum: Float = 0, rSum: Float = 0
        for k in keys {
            let M = manToItems[manual[k]!] ?? []
            let A = autoToItems[auto[k]!] ?? []
            let inter = Float(M.intersection(A).count)
            pSum += inter / Float(max(A.count, 1))
            rSum += inter / Float(max(M.count, 1))
        }
        let prec = pSum / Float(keys.count)
        let rec = rSum / Float(keys.count)
        let f1 = (prec + rec) == 0 ? 0 : 2 * prec * rec / (prec + rec)
        return (prec, rec, f1)
    }
    
    // Build many-to-one majority mapping Manual->Auto
    private func majorityMapping(tab: [[Int]], mLabels: [Int], aLabels: [Int]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for (ri, row) in tab.enumerated() {
            let (cj, _) = row.enumerated().max(by: { $0.element < $1.element }) ?? (0, 0)
            map[mLabels[ri]] = aLabels[cj]     // many-to-one allowed
        }
        return map
    }
    
    // Calculate mapped accuracy under many-to-one mapping
    private func mappedAccuracy(tab: [[Int]], rows: [Int], mLabels: [Int], aLabels: [Int]) -> Float {
        let map = majorityMapping(tab: tab, mLabels: mLabels, aLabels: aLabels)
        var acc = 0
        for (ri, m) in mLabels.enumerated() {
            if let a = map[m], let cj = aLabels.firstIndex(of: a) { 
                acc += tab[ri][cj] 
            }
        }
        let n = rows.reduce(0, +)
        return n == 0 ? 0 : Float(acc) / Float(n)
    }
    
    // Build confusion matrix for JSON/report
    private func buildConfusionMatrix(tab: [[Int]]) -> [[Int]] { 
        return tab 
    }
    
    private func centroids(for grouping: [String: Int], data: [SampleAnalysisData]) -> [Int: [Float]] {
        var sums: [Int: [Float]] = [:]
        var counts: [Int: Int] = [:]
        for s in data {
            if let g = grouping[s.id], !s.normalizedTimbreVector.isEmpty {
                var sum = sums[g] ?? Array(repeating: 0, count: s.normalizedTimbreVector.count)
                for i in 0..<sum.count { 
                    sum[i] += s.normalizedTimbreVector[i] 
                }
                sums[g] = sum
                counts[g, default: 0] += 1
            }
        }
        var cents: [Int: [Float]] = [:]
        for (g, sum) in sums {
            let c = Float(max(counts[g] ?? 1, 1))
            cents[g] = sum.map { $0 / c }
        }
        return cents
    }
    
    private func perClassPRF1FromConfusion(tab: [[Int]], rows: [Int], cols: [Int],
                                           mLabels: [Int], aLabels: [Int]) -> [Int: ClassMetrics] {
        let map = majorityMapping(tab: tab, mLabels: mLabels, aLabels: aLabels)
        var out: [Int: ClassMetrics] = [:]
        for (ri, m) in mLabels.enumerated() {
            guard let a = map[m], let cj = aLabels.firstIndex(of: a) else { continue }
            let tp = tab[ri][cj]
            let prec = cols[cj] == 0 ? 0 : Float(tp) / Float(cols[cj])
            let rec = rows[ri] == 0 ? 0 : Float(tp) / Float(rows[ri])
            let f1 = (prec + rec) == 0 ? 0 : 2 * prec * rec / (prec + rec)
            out[m] = ClassMetrics(precision: prec, recall: rec, f1: f1)
        }
        return out
    }
    
    private func findMergesAndSplits(tab: [[Int]], mLabels: [Int], aLabels: [Int]) -> (merges: [String], splits: [String]) {
        var merges: [String] = []
        var splits: [String] = []
        
        // Calculate row sums
        let rowSums = tab.map { row in row.reduce(0, +) }
        let colSums = (0..<aLabels.count).map { j in tab.reduce(0) { $0 + $1[j] } }
        
        // Find merges: multiple manual labels with significant share mapping to same auto label
        var autoToManualGroups: [Int: [(manual: Int, count: Int, share: Float)]] = [:]
        
        for (i, mLabel) in mLabels.enumerated() {
            let rowSum = rowSums[i]
            if rowSum == 0 { continue }
            
            for (j, aLabel) in aLabels.enumerated() {
                let count = tab[i][j]
                let share = Float(count) / Float(rowSum)
                if share >= 0.6 { // Significant share threshold
                    autoToManualGroups[aLabel, default: []].append((mLabel, count, share))
                }
            }
        }
        
        // Report merges with proportions
        for (aLabel, manualGroups) in autoToManualGroups where manualGroups.count > 1 {
            let sorted = manualGroups.sorted { $0.manual < $1.manual }
            let labels = sorted.map { "M\($0.manual)(\(Int($0.share * 100))%)" }.joined(separator: ", ")
            merges.append("{\(labels)} → Auto \(aLabel)")
        }
        
        // Find splits: manual label with significant proportions across multiple auto labels
        for (i, mLabel) in mLabels.enumerated() {
            let rowSum = rowSums[i]
            if rowSum == 0 { continue }
            
            var autoShares: [(auto: Int, count: Int, share: Float)] = []
            for (j, aLabel) in aLabels.enumerated() {
                let count = tab[i][j]
                let share = Float(count) / Float(rowSum)
                if share > 0 {
                    autoShares.append((aLabel, count, share))
                }
            }
            
            // Sort by share descending
            autoShares.sort { $0.share > $1.share }
            
            // Check if split (top share < 0.7 and second share >= 0.3)
            if autoShares.count >= 2 && autoShares[0].share < 0.7 && autoShares[1].share >= 0.3 {
                let topTwo = autoShares.prefix(2)
                let labels = topTwo.map { "A\($0.auto)(\(Int($0.share * 100))%)" }.joined(separator: ", ")
                splits.append("Manual \(mLabel) → {\(labels)}")
            }
        }
        
        return (merges, splits)
    }
    
    // MARK: - Clustering Quality Indices
    
    // Compute centroids and per-cluster scatter Si (mean distance to centroid)
    private func clusterCentroidsAndScatter(X: [[Float]], y: [Int]) -> (cents: [Int: [Float]], S: [Int: Float], groups: [Int: [Int]]) {
        let idxByG = Dictionary(grouping: Array(0..<y.count), by: { y[$0] })
        var cents: [Int: [Float]] = [:], S: [Int: Float] = [:]
        for (g, idxs) in idxByG {
            guard let d = X.first?.count, !idxs.isEmpty else { continue }
            var sum = Array(repeating: Float(0), count: d)
            for i in idxs { 
                for k in 0..<d { 
                    sum[k] += X[i][k] 
                } 
            }
            let c = sum.map { $0 / Float(idxs.count) }
            cents[g] = c
            // mean Euclidean distance to centroid
            var s: Float = 0
            for i in idxs {
                var dist: Float = 0
                for k in 0..<d { 
                    let t = X[i][k] - c[k]
                    dist += t * t 
                }
                s += sqrtf(dist)
            }
            S[g] = s / Float(idxs.count)
        }
        return (cents, S, idxByG)
    }
    
    // Davies-Bouldin Index: average over i of max_j (S_i + S_j) / M_ij
    private func daviesBouldin(X: [[Float]], y: [Int]) -> Float {
        let (C, S, _) = clusterCentroidsAndScatter(X: X, y: y)
        let labels = Array(C.keys)
        guard labels.count > 1 else { return 0 }
        
        func distC(_ a: [Float], _ b: [Float]) -> Float {
            var s: Float = 0
            for k in 0..<min(a.count, b.count) { 
                let d = a[k] - b[k]
                s += d * d 
            }
            return sqrtf(s)
        }
        
        var sum: Float = 0
        for i in labels {
            var worst = Float.leastNonzeroMagnitude
            for j in labels where j != i {
                let m = distC(C[i]!, C[j]!)
                if m > 0 {
                    let r = (S[i]! + S[j]!) / m
                    if r > worst { worst = r }
                }
            }
            sum += worst
        }
        return sum / Float(labels.count)
    }
    
    // Calinski-Harabasz Index: (trace(B)/(k-1)) / (trace(W)/(n-k))
    private func calinskiHarabasz(X: [[Float]], y: [Int]) -> Float {
        let n = X.count
        guard n > 2 else { return 0 }
        let k = Set(y).count
        guard k > 1 && k < n else { return 0 }
        
        // overall mean
        let d = X.first?.count ?? 0
        var mu = Array(repeating: Float(0), count: d)
        for v in X { 
            for i in 0..<d { 
                mu[i] += v[i] 
            } 
        }
        for i in 0..<d { 
            mu[i] /= Float(n) 
        }
        
        // group means
        let (C, _, G) = clusterCentroidsAndScatter(X: X, y: y)
        
        // trace(W) - within-cluster sum of squares
        var W: Float = 0
        for (g, idxs) in G {
            let c = C[g]!
            for i in idxs {
                var s: Float = 0
                for j in 0..<d { 
                    let t = X[i][j] - c[j]
                    s += t * t 
                }
                W += s
            }
        }
        
        // trace(B) - between-cluster sum of squares
        var B: Float = 0
        for (g, idxs) in G {
            let c = C[g]!
            var s: Float = 0
            for j in 0..<d { 
                let t = c[j] - mu[j]
                s += t * t 
            }
            B += Float(idxs.count) * s
        }
        
        return (B / Float(k - 1)) / (W / Float(n - k))
    }
    
    // Calculate sample ambiguity (margin between nearest and second nearest clusters)
    private func calculateSampleAmbiguity(X: [[Float]], y: [Int], centroids: [Int: [Float]]) 
    -> [(nearest: Int, secondNearest: Int?, margin: Float)] {
        var results: [(nearest: Int, secondNearest: Int?, margin: Float)] = []
        
        for (idx, vector) in X.enumerated() {
            var distances: [(cluster: Int, dist: Float)] = []
            
            for (cluster, centroid) in centroids {
                let dist = euclid(vector, centroid)
                distances.append((cluster, dist))
            }
            
            distances.sort { $0.dist < $1.dist }
            
            let nearest = distances[0].cluster
            let secondNearest = distances.count > 1 ? distances[1].cluster : nil
            let margin = distances.count > 1 && distances[0].dist > 0 ? 
                distances[1].dist / distances[0].dist : Float.infinity
            
            results.append((nearest, secondNearest, margin))
        }
        
        return results
    }
    
    // One-to-one Hungarian mapping for comparison
    private func hungarianMapping(tab: [[Int]], mLabels: [Int], aLabels: [Int]) -> [Int: Int] {
        // Simple greedy approximation of Hungarian algorithm
        var map: [Int: Int] = [:]
        var usedA = Set<Int>()
        
        // Create cost matrix (negative of contingency for maximization)
        var costs: [(m: Int, a: Int, count: Int)] = []
        for (i, mLabel) in mLabels.enumerated() {
            for (j, aLabel) in aLabels.enumerated() {
                if tab[i][j] > 0 {
                    costs.append((mLabel, aLabel, tab[i][j]))
                }
            }
        }
        
        // Sort by count descending
        costs.sort { $0.count > $1.count }
        
        // Greedy assignment
        for cost in costs {
            if !map.keys.contains(cost.m) && !usedA.contains(cost.a) {
                map[cost.m] = cost.a
                usedA.insert(cost.a)
            }
        }
        
        return map
    }
    
    // Calculate one-to-one accuracy
    private func oneToOneAccuracy(tab: [[Int]], rows: [Int], mLabels: [Int], aLabels: [Int]) -> Float {
        let map = hungarianMapping(tab: tab, mLabels: mLabels, aLabels: aLabels)
        var acc = 0
        for (ri, m) in mLabels.enumerated() {
            if let a = map[m], let cj = aLabels.firstIndex(of: a) {
                acc += tab[ri][cj]
            }
        }
        let n = rows.reduce(0, +)
        return n == 0 ? 0 : Float(acc) / Float(n)
    }
    
    // MARK: - K-Calibration Methods
    
    // Overall quality score combining multiple metrics
    func overallQualityScore(_ q: ClusterQuality) -> Float {
        let sil = q.silhouetteGlobal
        let db = q.daviesBouldin ?? .nan
        let ch = q.calinskiHarabasz ?? .nan
        
        var score = sil
        if db.isFinite { 
            score += max(0, 1.0 - min(db, 2.0)) * 0.2 
        }
        if ch.isFinite { 
            score += min(ch / 1000.0, 0.2) 
        }
        return score
    }
    
    // Selection objective for K preference
    func selectionObjective(sil: Float, ch: Float?, db: Float?, k: Int, targetK: Int, lambda: Float = 0.15) -> Float {
        var score = sil
        if let chv = ch { score += min(chv / 1000.0, 0.2) }
        if let dbv = db { score += max(0, 1.0 - min(dbv, 2.0)) * 0.2 }
        let kPenalty = -lambda * powf(Float(k - targetK), 2)
        return score + kPenalty
    }
    
    // Recompute clustering state after modifications
    private func recomputeState(_ state: ClusteringState) -> ClusteringState {
        var state = state
        
        // Get vectors and labels arrays
        let ids = Array(state.labelsById.keys)
        let X = ids.compactMap { state.vectorsById[$0] }
        let y = ids.compactMap { state.labelsById[$0] }
        
        guard !X.isEmpty else { return state }
        
        // Recompute centroids
        state.centroids = [:]
        let groups = Dictionary(grouping: Array(0..<y.count), by: { y[$0] })
        for (g, indices) in groups {
            guard let d = X.first?.count, !indices.isEmpty else { continue }
            var sum = Array(repeating: Float(0), count: d)
            for i in indices {
                for k in 0..<d {
                    sum[k] += X[i][k]
                }
            }
            state.centroids[g] = sum.map { $0 / Float(indices.count) }
        }
        
        // Recompute quality metrics
        let (silGlobal, silByCluster) = silhouetteScores(analysisData: [], grouping: state.labelsById)
        let dbi = daviesBouldin(X: X, y: y)
        let ch = calinskiHarabasz(X: X, y: y)
        
        state.quality = ClusterQuality(
            silhouetteGlobal: silGlobal,
            daviesBouldin: dbi,
            calinskiHarabasz: ch
        )
        state.silhouetteByCluster = silByCluster
        
        return state
    }
    
    // Calibrate clusters to target K
    func calibrateClustersToK(targetK: Int, state: ClusteringState) -> ClusteringState {
        var st = state
        var iterations = 0
        let maxIterations = 10
        
        while iterations < maxIterations {
            let currentK = Set(st.labelsById.values).count
            if currentK == targetK { break }
            
            if currentK < targetK {
                // Need to SPLIT the worst cluster (lowest silhouette)
                guard let cToSplit = st.silhouetteByCluster.min(by: { $0.value < $1.value })?.key else { break }
                st = splitCluster(st, clusterId: cToSplit)
            } else {
                // Need to MERGE the closest pair of clusters
                st = mergeBestPair(st)
            }
            
            iterations += 1
        }
        
        return st
    }
    
    // Split a cluster into two
    private func splitCluster(_ st: ClusteringState, clusterId: Int) -> ClusteringState {
        var st = st
        let members = st.labelsById.filter { $0.value == clusterId }.map { $0.key }
        guard members.count >= 4 else { return st }
        
        let X = members.compactMap { st.vectorsById[$0] }
        
        // Run local 2-means
        let (assign, _) = localBisectingKMeans(vectors: X, k: 2)
        
        // Re-label: keep original cluster ID for group 0, create new ID for group 1
        let newB = (st.centroids.keys.max() ?? clusterId) + 1
        for (i, id) in members.enumerated() {
            st.labelsById[id] = (assign[i] == 0) ? clusterId : newB
        }
        
        // Recompute state
        return recomputeState(st)
    }
    
    // Merge best pair of clusters
    private func mergeBestPair(_ st: ClusteringState) -> ClusteringState {
        var best: (Float, (Int, Int), ClusteringState)? = nil
        let clusters = Array(Set(st.labelsById.values))
        
        // Try all pairs
        for i in 0..<clusters.count {
            for j in i+1..<clusters.count {
                let a = clusters[i], b = clusters[j]
                var next = st
                
                // Relabel all of 'b' as 'a'
                for (id, g) in next.labelsById where g == b {
                    next.labelsById[id] = a
                }
                
                next = recomputeState(next)
                let score = overallQualityScore(next.quality)
                
                if best == nil || score > best!.0 {
                    best = (score, (a, b), next)
                }
            }
        }
        
        return best?.2 ?? st
    }
    
    // Local bisecting k-means
    private func localBisectingKMeans(vectors: [[Float]], k: Int = 2) -> ([Int], [[Float]]) {
        guard vectors.count >= k else {
            return (Array(repeating: 0, count: vectors.count), [vectors.first ?? []])
        }
        
        // Initialize with two furthest points
        var maxDist: Float = 0
        var p1 = 0, p2 = 1
        
        for i in 0..<vectors.count {
            for j in i+1..<vectors.count {
                let dist = euclid(vectors[i], vectors[j])
                if dist > maxDist {
                    maxDist = dist
                    p1 = i
                    p2 = j
                }
            }
        }
        
        var centroids = [vectors[p1], vectors[p2]]
        var labels = Array(repeating: 0, count: vectors.count)
        
        // Run a few iterations
        for _ in 0..<10 {
            // Assignment
            var changed = false
            for (i, vec) in vectors.enumerated() {
                let d1 = euclid(vec, centroids[0])
                let d2 = euclid(vec, centroids[1])
                let newLabel = d1 <= d2 ? 0 : 1
                if labels[i] != newLabel {
                    labels[i] = newLabel
                    changed = true
                }
            }
            
            if !changed { break }
            
            // Update centroids
            for c in 0..<2 {
                let members = vectors.enumerated().filter { labels[$0.offset] == c }.map { $0.element }
                if !members.isEmpty {
                    centroids[c] = calculateCentroid(members)
                }
            }
        }
        
        return (labels, centroids)
    }
    
    // Calculate centroid of a set of vectors
    private func calculateCentroid(_ vectors: [[Float]]) -> [Float] {
        guard !vectors.isEmpty else { return [] }
        
        let dim = vectors[0].count
        var centroid = [Float](repeating: 0, count: dim)
        
        for vector in vectors {
            for i in 0..<dim {
                centroid[i] += vector[i]
            }
        }
        
        let count = Float(vectors.count)
        return centroid.map { $0 / count }
    }
}

// Note: The extractFeatures and zScoreNormalize functions are now public in SampleSimilarity.swift

// MARK: - K-Calibration System

struct ClusterQuality {
    let silhouetteGlobal: Float      // higher is better
    let daviesBouldin: Float?        // lower is better
    let calinskiHarabasz: Float?     // higher is better
}

struct ClusteringState {
    var labelsById: [String: Int]                    // sampleId -> auto cluster
    var vectorsById: [String: [Float]]               // sampleId -> feature vector
    var quality: ClusterQuality
    var centroids: [Int: [Float]]
    var silhouetteByCluster: [Int: Float]
}

// MARK: - Extensions

extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}