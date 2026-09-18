import Foundation

// MARK: - Improved Grouping Strategy

public struct ImprovedGroupingStrategy {
    
    /// Analyze test results and suggest parameter adjustments
    static func analyzeTestResults(
        testSession: GroupingTestSession
    ) -> GroupingRecommendations {
        
        // Analyze RMS distribution
        let rmsValues = testSession.samples.map { $0.rms }.sorted()
        let rmsRanges = identifyRMSClusters(rmsValues)
        
        // Analyze spectral distribution within each RMS range
        var spectralPatterns: [Int: SpectralPattern] = [:]
        for (idx, range) in rmsRanges.enumerated() {
            let samplesInRange = testSession.samples.filter { 
                $0.rms >= range.min && $0.rms <= range.max 
            }
            spectralPatterns[idx] = analyzeSpectralPattern(samplesInRange)
        }
        
        // Compare with manual grouping
        let manualGroupStats = analyzeManualGrouping(testSession)
        
        return GroupingRecommendations(
            suggestedClusters: rmsRanges.count,
            loudnessWeight: calculateOptimalLoudnessWeight(
                manual: manualGroupStats,
                automatic: testSession.automaticGrouping
            ),
            clusteringMethod: recommendClusteringMethod(testSession),
            rmsThresholds: rmsRanges.map { $0.max },
            spectralWeights: calculateSpectralWeights(spectralPatterns)
        )
    }
    
    /// Identify natural RMS clusters using kernel density estimation
    private static func identifyRMSClusters(_ sortedRMS: [Float]) -> [(min: Float, max: Float)] {
        guard sortedRMS.count > 1 else { return [(sortedRMS.first ?? 0, sortedRMS.first ?? 0)] }
        
        // Calculate gaps between consecutive RMS values
        var gaps: [(index: Int, gap: Float)] = []
        for i in 1..<sortedRMS.count {
            let gap = sortedRMS[i] - sortedRMS[i-1]
            gaps.append((i, gap))
        }
        
        // Find significant gaps (using median absolute deviation)
        let sortedGaps = gaps.map { $0.gap }.sorted()
        let medianGap = sortedGaps[sortedGaps.count / 2]
        let mad = sortedGaps.map { abs($0 - medianGap) }.sorted()[sortedGaps.count / 2]
        let threshold = medianGap + 2.5 * mad
        
        // Create clusters based on significant gaps
        var clusters: [(min: Float, max: Float)] = []
        var currentMin = sortedRMS[0]
        
        for gap in gaps {
            if gap.gap > threshold {
                clusters.append((currentMin, sortedRMS[gap.index - 1]))
                currentMin = sortedRMS[gap.index]
            }
        }
        clusters.append((currentMin, sortedRMS.last!))
        
        return clusters
    }
    
    /// Analyze spectral characteristics within an RMS range
    private static func analyzeSpectralPattern(_ samples: [SampleAnalysisData]) -> SpectralPattern {
        guard !samples.isEmpty else {
            return SpectralPattern(
                meanCentroid: 0,
                centroidVariance: 0,
                dominantFeatures: []
            )
        }
        
        let centroids = samples.map { $0.spectralCentroidHz }
        let mean = centroids.reduce(0, +) / Float(centroids.count)
        let variance = centroids.map { pow($0 - mean, 2) }.reduce(0, +) / Float(centroids.count)
        
        // Determine which spectral features vary most within this RMS range
        let features = [
            ("centroid", variance),
            ("rolloff", calculateVariance(samples.map { $0.spectralRolloffHz })),
            ("bandwidth", calculateVariance(samples.map { $0.spectralBandwidthHz })),
            ("flatness", calculateVariance(samples.map { $0.spectralFlatness })),
            ("zcr", calculateVariance(samples.map { $0.zeroCrossingRate }))
        ]
        
        let dominantFeatures = features
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            .map { $0.0 }
        
        return SpectralPattern(
            meanCentroid: mean,
            centroidVariance: variance,
            dominantFeatures: dominantFeatures
        )
    }
    
    private static func calculateVariance(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Float(values.count)
        return values.map { pow($0 - mean, 2) }.reduce(0, +) / Float(values.count)
    }
    
    /// Analyze manual grouping patterns
    private static func analyzeManualGrouping(_ session: GroupingTestSession) -> ManualGroupStats {
        var groupStats: [Int: GroupCharacteristics] = [:]
        
        for (groupId, sampleIds) in session.manualGrouping {
            let samples = session.samples.filter { sampleIds.contains($0.id) }
            guard !samples.isEmpty else { continue }
            
            let rmsValues = samples.map { $0.rms }
            let centroids = samples.map { $0.spectralCentroidHz }
            
            groupStats[groupId] = GroupCharacteristics(
                meanRMS: rmsValues.reduce(0, +) / Float(rmsValues.count),
                rmsRange: (rmsValues.min() ?? 0, rmsValues.max() ?? 0),
                meanCentroid: centroids.reduce(0, +) / Float(centroids.count),
                centroidRange: (centroids.min() ?? 0, centroids.max() ?? 0),
                sampleCount: samples.count
            )
        }
        
        return ManualGroupStats(groups: groupStats)
    }
    
    /// Calculate optimal loudness weight based on manual grouping patterns
    private static func calculateOptimalLoudnessWeight(
        manual: ManualGroupStats,
        automatic: [Int: [String]]
    ) -> Float {
        
        // Check if manual groups are primarily separated by RMS
        let groups = Array(manual.groups.values).sorted { $0.meanRMS < $1.meanRMS }
        guard groups.count > 1 else { return 0.3 }
        
        // Calculate RMS separation between consecutive groups
        var rmsSeparations: [Float] = []
        for i in 1..<groups.count {
            let separation = groups[i].meanRMS - groups[i-1].meanRMS
            let overlap = groups[i].rmsRange.0 < groups[i-1].rmsRange.1
            rmsSeparations.append(overlap ? 0 : separation)
        }
        
        // Calculate spectral separation
        var spectralSeparations: [Float] = []
        for i in 1..<groups.count {
            let separation = abs(groups[i].meanCentroid - groups[i-1].meanCentroid)
            spectralSeparations.append(separation)
        }
        
        // Weight based on which separation is more consistent
        let rmsConsistency = 1.0 - (calculateVariance(rmsSeparations) / (rmsSeparations.max() ?? 1))
        let spectralConsistency = 1.0 - (calculateVariance(spectralSeparations) / (spectralSeparations.max() ?? 1))
        
        // Higher weight for loudness if RMS separation is more consistent
        let loudnessWeight = rmsConsistency / (rmsConsistency + spectralConsistency)
        
        return min(0.6, max(0.2, loudnessWeight))
    }
    
    /// Recommend clustering method based on data characteristics
    private static func recommendClusteringMethod(_ session: GroupingTestSession) -> ClusteringMethod {
        let sampleCount = session.samples.count
        let manualGroupCount = session.manualGrouping.count
        
        // Analyze group size distribution
        let groupSizes = session.manualGrouping.values.map { $0.count }
        let sizeVariance = calculateVariance(groupSizes.map { Float($0) })
        
        // Check if groups have clear hierarchical structure
        let hasHierarchicalStructure = analyzeHierarchicalStructure(session)
        
        if hasHierarchicalStructure {
            return .hierarchical
        } else if sizeVariance > Float(sampleCount) * 0.1 {
            return .dbscan // For uneven cluster sizes
        } else {
            return .kMeans // For roughly equal cluster sizes
        }
    }
    
    private static func analyzeHierarchicalStructure(_ session: GroupingTestSession) -> Bool {
        // Check if manual groups can be organized in a hierarchy
        // (e.g., groups 1-2 are quiet, 3-4 are medium, 5 is loud)
        let groupStats = analyzeManualGrouping(session)
        let sortedGroups = groupStats.groups.sorted { $0.value.meanRMS < $1.value.meanRMS }
        
        // Look for natural groupings at a higher level
        var superGroups: [[Int]] = []
        var currentSuperGroup: [Int] = []
        var lastRMS: Float = 0
        
        for (groupId, stats) in sortedGroups {
            if currentSuperGroup.isEmpty || (stats.meanRMS - lastRMS) < 0.01 {
                currentSuperGroup.append(groupId)
            } else {
                superGroups.append(currentSuperGroup)
                currentSuperGroup = [groupId]
            }
            lastRMS = stats.meanRMS
        }
        if !currentSuperGroup.isEmpty {
            superGroups.append(currentSuperGroup)
        }
        
        // Hierarchical if we have 2-3 super groups with multiple sub-groups
        return superGroups.count >= 2 && superGroups.count <= 3 && 
               superGroups.filter { $0.count > 1 }.count >= 1
    }
    
    /// Calculate spectral feature weights based on importance
    private static func calculateSpectralWeights(_ patterns: [Int: SpectralPattern]) -> [String: Float] {
        var featureImportance: [String: Float] = [
            "centroid": 0,
            "rolloff": 0,
            "bandwidth": 0,
            "flatness": 0,
            "zcr": 0
        ]
        
        // Accumulate importance based on how often each feature is dominant
        for pattern in patterns.values {
            for (index, feature) in pattern.dominantFeatures.enumerated() {
                let weight = 1.0 / Float(index + 1) // Higher weight for more dominant features
                featureImportance[feature, default: 0] += weight
            }
        }
        
        // Normalize weights
        let total = featureImportance.values.reduce(0, +)
        if total > 0 {
            for key in featureImportance.keys {
                featureImportance[key]! /= total
            }
        }
        
        return featureImportance
    }
}

// MARK: - Supporting Types

public struct GroupingRecommendations {
    let suggestedClusters: Int
    let loudnessWeight: Float
    let clusteringMethod: ClusteringMethod
    let rmsThresholds: [Float]
    let spectralWeights: [String: Float]
    
    /// Generate improved clustering options based on recommendations
    public func toClusteringOptions() -> ClusteringOptions {
        ClusteringOptions(
            method: clusteringMethod,
            minClusters: max(2, suggestedClusters - 1),
            maxClusters: min(8, suggestedClusters + 1),
            loudnessWeight: loudnessWeight,
            adaptiveWindowing: true
        )
    }
}

struct SpectralPattern {
    let meanCentroid: Float
    let centroidVariance: Float
    let dominantFeatures: [String]
}

struct GroupCharacteristics {
    let meanRMS: Float
    let rmsRange: (Float, Float)
    let meanCentroid: Float
    let centroidRange: (Float, Float)
    let sampleCount: Int
}

struct ManualGroupStats {
    let groups: [Int: GroupCharacteristics]
}

// MARK: - Two-Stage Clustering Approach

func twoStageGroupSamples(
    urls: [URL],
    testSession: GroupingTestSession? = nil
) throws -> [[URL]] {
    
    // Get recommendations if test session provided
    let recommendations = testSession.map { ImprovedGroupingStrategy.analyzeTestResults(testSession: $0) }
    
    // Extract features
    let features = try urls.map { try extractEnhancedFeatures(from: $0) }
    
    // Stage 1: Group by loudness (RMS)
    let rmsGroups = groupByLoudness(
        features: features,
        thresholds: recommendations?.rmsThresholds
    )
    
    // Stage 2: Within each loudness group, cluster by spectral features
    var finalGroups: [[URL]] = []
    
    for (rmsGroupIdx, rmsGroup) in rmsGroups.enumerated() {
        if rmsGroup.count <= 3 {
            // Small group, keep together
            finalGroups.append(rmsGroup.map { urls[$0] })
        } else {
            // Sub-cluster by spectral features
            let spectralGroups = clusterBySpectralFeatures(
                indices: rmsGroup,
                features: features,
                weights: recommendations?.spectralWeights ?? [:]
            )
            
            for spectralGroup in spectralGroups {
                finalGroups.append(spectralGroup.map { urls[$0] })
            }
        }
    }
    
    return finalGroups
}

/// Group samples by loudness levels
private func groupByLoudness(
    features: [EnhancedSampleFeatures],
    thresholds: [Float]? = nil
) -> [[Int]] {
    
    let sortedIndices = features.indices.sorted { features[$0].rms < features[$1].rms }
    
    if let thresholds = thresholds {
        // Use provided thresholds
        var groups: [[Int]] = Array(repeating: [], count: thresholds.count + 1)
        
        for idx in sortedIndices {
            let rms = features[idx].rms
            var groupIdx = 0
            for threshold in thresholds {
                if rms > threshold {
                    groupIdx += 1
                } else {
                    break
                }
            }
            groups[groupIdx].append(idx)
        }
        
        return groups.filter { !$0.isEmpty }
    } else {
        // Auto-detect thresholds using Jenks natural breaks
        return jenksNaturalBreaks(
            values: features.map { $0.rms },
            numClasses: determineOptimalLoudnessGroups(features)
        )
    }
}

/// Cluster by spectral features within a loudness group
private func clusterBySpectralFeatures(
    indices: [Int],
    features: [EnhancedSampleFeatures],
    weights: [String: Float]
) -> [[Int]] {
    
    guard indices.count > 1 else { return [indices] }
    
    // Create weighted feature vectors
    var vectors: [[Float]] = []
    for idx in indices {
        let feat = features[idx]
        var vector: [Float] = []
        
        // Add weighted spectral features
        vector.append(feat.spectralCentroidHz * (weights["centroid"] ?? 0.3))
        vector.append(feat.spectralRolloffHz * (weights["rolloff"] ?? 0.2))
        vector.append(feat.spectralBandwidthHz * (weights["bandwidth"] ?? 0.2))
        vector.append(feat.spectralFlatness * (weights["flatness"] ?? 0.15))
        vector.append(feat.zeroCrossingRate * (weights["zcr"] ?? 0.15))
        
        vectors.append(vector)
    }
    
    // Normalize vectors
    let normalized = normalizeVectors(vectors)
    
    // Determine optimal number of sub-clusters
    let k = min(indices.count / 3, 3) // Max 3 sub-clusters per loudness group
    
    if k <= 1 {
        return [indices]
    }
    
    // Perform clustering
    let (labels, _) = simpleKMeans(vectors: normalized, k: k)
    
    // Group indices by cluster label
    var groups: [[Int]] = Array(repeating: [], count: k)
    for (i, label) in labels.enumerated() {
        groups[label].append(indices[i])
    }
    
    return groups.filter { !$0.isEmpty }
}

/// Jenks Natural Breaks algorithm for optimal grouping
private func jenksNaturalBreaks(values: [Float], numClasses: Int) -> [[Int]] {
    let sorted = values.enumerated().sorted { $0.element < $1.element }
    let n = sorted.count
    
    guard n > numClasses else {
        return sorted.map { [$0.offset] }
    }
    
    // Simple implementation - divide into roughly equal groups
    var groups: [[Int]] = Array(repeating: [], count: numClasses)
    let groupSize = n / numClasses
    
    for (i, item) in sorted.enumerated() {
        let groupIdx = min(i / groupSize, numClasses - 1)
        groups[groupIdx].append(item.offset)
    }
    
    return groups
}

/// Determine optimal number of loudness groups
private func determineOptimalLoudnessGroups(_ features: [EnhancedSampleFeatures]) -> Int {
    let rmsValues = features.map { $0.rms }.sorted()
    
    // Calculate gaps and find natural breaks
    var maxGap: Float = 0
    var gapCount = 0
    
    for i in 1..<rmsValues.count {
        let gap = rmsValues[i] - rmsValues[i-1]
        if gap > maxGap * 0.5 { // Significant gap
            gapCount += 1
            maxGap = max(maxGap, gap)
        }
    }
    
    // Typically 2-4 loudness groups work well
    return min(4, max(2, gapCount + 1))
}

/// Normalize vectors to unit variance
private func normalizeVectors(_ vectors: [[Float]]) -> [[Float]] {
    guard !vectors.isEmpty, let first = vectors.first else { return vectors }
    let dims = first.count
    
    var normalized = vectors
    
    for d in 0..<dims {
        let values = vectors.map { $0[d] }
        let mean = values.reduce(0, +) / Float(values.count)
        let variance = values.map { pow($0 - mean, 2) }.reduce(0, +) / Float(values.count)
        let std = sqrt(max(variance, 1e-6))
        
        for i in 0..<vectors.count {
            normalized[i][d] = (vectors[i][d] - mean) / std
        }
    }
    
    return normalized
}

// MARK: - Simple K-Means Implementation

private func simpleKMeans(vectors: [[Float]], k: Int) -> (labels: [Int], centroids: [[Float]]) {
    guard !vectors.isEmpty && k > 0 else { return ([], []) }
    
    // Initialize centroids randomly
    var centroids = Array(vectors.shuffled().prefix(k))
    var labels = [Int](repeating: 0, count: vectors.count)
    
    for _ in 0..<50 { // Max iterations
        var changed = false
        
        // Assignment step
        for (i, vector) in vectors.enumerated() {
            var bestCluster = 0
            var bestDist = Float.greatestFiniteMagnitude
            
            for (j, centroid) in centroids.enumerated() {
                let dist = euclideanDistance(vector, centroid)
                if dist < bestDist {
                    bestDist = dist
                    bestCluster = j
                }
            }
            
            if labels[i] != bestCluster {
                labels[i] = bestCluster
                changed = true
            }
        }
        
        if !changed { break }
        
        // Update step
        for c in 0..<k {
            let members = vectors.enumerated().filter { labels[$0.offset] == c }.map { $0.element }
            if !members.isEmpty {
                centroids[c] = calculateCentroid(members)
            }
        }
    }
    
    return (labels, centroids)
}

private func euclideanDistance(_ a: [Float], _ b: [Float]) -> Float {
    var sum: Float = 0
    for i in 0..<min(a.count, b.count) {
        let diff = a[i] - b[i]
        sum += diff * diff
    }
    return sqrt(sum)
}

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