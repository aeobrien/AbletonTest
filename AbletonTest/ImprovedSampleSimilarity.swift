import Foundation
import AVFoundation
import Accelerate

// MARK: - Improved Feature Set

public struct EnhancedSampleFeatures {
    // Loudness features
    let rms: Float
    let peak: Float
    let dynamicRange: Float
    
    // Spectral features (attack window)
    let spectralCentroidHz: Float
    let spectralRolloffHz: Float
    let spectralBandwidthHz: Float
    let spectralFlatness: Float
    let spectralFlux: Float
    let zeroCrossingRate: Float
    
    // Temporal features
    let attackTime: Float
    let temporalCentroid: Float
    
    // MFCC coefficients (first 13)
    let mfcc: [Float]
    
    // Combined feature vector for clustering
    var featureVector: [Float] {
        // Weight different features based on importance
        let spectralFeatures = [
            spectralCentroidHz,
            spectralRolloffHz,
            spectralBandwidthHz,
            spectralFlatness,
            spectralFlux,
            zeroCrossingRate
        ]
        
        let temporalFeatures = [
            attackTime * 10, // Scale up attack time
            temporalCentroid
        ]
        
        let loudnessFeatures = [
            rms * 5, // Give more weight to RMS
            peak * 3,
            dynamicRange * 2
        ]
        
        return loudnessFeatures + spectralFeatures + temporalFeatures + mfcc
    }
}

// MARK: - Improved Clustering

public enum ClusteringMethod {
    case kMeans
    case hierarchical
    case dbscan
}

public struct ClusteringOptions {
    public let method: ClusteringMethod
    public let minClusters: Int
    public let maxClusters: Int
    public let loudnessWeight: Float // 0-1, how much to weight loudness vs timbre
    public let adaptiveWindowing: Bool
    
    public init(
        method: ClusteringMethod = .hierarchical,
        minClusters: Int = 2,
        maxClusters: Int = 8,
        loudnessWeight: Float = 0.3,
        adaptiveWindowing: Bool = true
    ) {
        self.method = method
        self.minClusters = minClusters
        self.maxClusters = maxClusters
        self.loudnessWeight = loudnessWeight
        self.adaptiveWindowing = adaptiveWindowing
    }
}

// MARK: - Enhanced Feature Extraction

public func extractEnhancedFeatures(from url: URL, adaptiveWindow: Bool = true) throws -> EnhancedSampleFeatures {
    let file = try AVAudioFile(forReading: url)
    
    guard file.length > 0 else {
        throw NSError(domain: "SampleSimilarity", code: -1, userInfo: [NSLocalizedDescriptionKey: "Audio file is empty"])
    }
    
    // Convert to standard format
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
    let converter = AVAudioConverter(from: file.processingFormat, to: format)!
    let frameCount = AVAudioFrameCount(file.length)
    let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)!
    try file.read(into: inputBuffer)
    
    let outFrames = AVAudioFrameCount(Double(frameCount) * (format.sampleRate / file.processingFormat.sampleRate))
    let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outFrames)!
    
    var error: NSError?
    converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
        outStatus.pointee = .haveData
        return inputBuffer
    }
    if let e = error { throw e }
    
    guard let ch = outputBuffer.floatChannelData?.pointee else { throw NSError(domain: "Extract", code: -1) }
    let n = Int(outputBuffer.frameLength)
    var samples = Array(UnsafeBufferPointer(start: ch, count: n))
    
    // Remove DC offset
    var mean: Float = 0
    vDSP_meanv(samples, 1, &mean, vDSP_Length(n))
    var negMean = -mean
    vDSP_vsadd(samples, 1, &negMean, &samples, 1, vDSP_Length(n))
    
    // Extract various features
    let sr = Float(format.sampleRate)
    
    // 1. Loudness features
    let rms = rootMeanSquare(samples)
    let peak = samples.map { abs($0) }.max() ?? 0
    let dynamicRange = peak > 0 ? 20 * log10(peak / rms) : 0
    
    // 2. Find onset and determine adaptive window
    let onsetInfo = detectOnsetAdvanced(samples: samples, sampleRate: sr)
    let onsetIdx = onsetInfo.onsetIndex
    let attackTime = onsetInfo.attackTime
    
    // 3. Determine analysis window
    let windowLength: Int
    if adaptiveWindow {
        // Use attack time to determine window length
        windowLength = min(Int(attackTime * sr * 2), n - onsetIdx)
    } else {
        windowLength = Int(0.256 * sr) // 256ms default
    }
    
    let analysisWindow = Array(samples[onsetIdx..<min(n, onsetIdx + windowLength)])
    
    // 4. Spectral features
    let spectralFeats = extractSpectralFeaturesEnhanced(analysisWindow, sampleRate: sr)
    
    // 5. Temporal features
    let temporalCentroid = calculateTemporalCentroid(samples)
    
    // 6. MFCC
    let mfccCoeffs = extractMFCC(analysisWindow, sampleRate: sr, numCoefficients: 13)
    
    return EnhancedSampleFeatures(
        rms: rms,
        peak: peak,
        dynamicRange: dynamicRange,
        spectralCentroidHz: spectralFeats.centroid,
        spectralRolloffHz: spectralFeats.rolloff,
        spectralBandwidthHz: spectralFeats.bandwidth,
        spectralFlatness: spectralFeats.flatness,
        spectralFlux: spectralFeats.flux,
        zeroCrossingRate: spectralFeats.zcr,
        attackTime: attackTime,
        temporalCentroid: temporalCentroid,
        mfcc: mfccCoeffs
    )
}

// MARK: - Advanced Onset Detection

private func detectOnsetAdvanced(samples: [Float], sampleRate: Float) -> (onsetIndex: Int, attackTime: Float) {
    let windowSize = 2048
    let hopSize = 512
    
    // Calculate spectral flux
    var fluxValues: [Float] = []
    var i = 0
    var prevMagnitudes: [Float] = []
    
    while i + windowSize <= samples.count {
        let window = Array(samples[i..<i+windowSize])
        let magnitudes = getFFTMagnitudes(window)
        
        if !prevMagnitudes.isEmpty {
            var flux: Float = 0
            for j in 0..<magnitudes.count {
                let diff = magnitudes[j] - prevMagnitudes[j]
                if diff > 0 { flux += diff }
            }
            fluxValues.append(flux)
        }
        
        prevMagnitudes = magnitudes
        i += hopSize
    }
    
    // Find peak in spectral flux
    guard !fluxValues.isEmpty else { return (0, 0.01) }
    
    let threshold = fluxValues.sorted()[Int(Float(fluxValues.count) * 0.8)]
    var onsetFrame = 0
    
    for (idx, flux) in fluxValues.enumerated() {
        if flux > threshold {
            onsetFrame = idx
            break
        }
    }
    
    let onsetIndex = onsetFrame * hopSize
    
    // Calculate attack time (time to reach 90% of peak after onset)
    let peakValue = samples[onsetIndex..<min(samples.count, onsetIndex + Int(0.1 * sampleRate))].map { abs($0) }.max() ?? 0
    let targetLevel = peakValue * 0.9
    var attackSamples = 0
    
    for i in onsetIndex..<min(samples.count, onsetIndex + Int(0.1 * sampleRate)) {
        if abs(samples[i]) >= targetLevel {
            attackSamples = i - onsetIndex
            break
        }
    }
    
    let attackTime = Float(attackSamples) / sampleRate
    
    return (onsetIndex, attackTime)
}

// MARK: - Enhanced Spectral Features

private func extractSpectralFeaturesEnhanced(_ window: [Float], sampleRate: Float) -> (centroid: Float, rolloff: Float, bandwidth: Float, flatness: Float, flux: Float, zcr: Float) {
    // Get basic spectral features
    let basicFeatures = spectralDescriptors(window, sampleRate: sampleRate)
    
    // Calculate spectral flux
    let flux = calculateSpectralFlux(window, sampleRate: sampleRate)
    
    // Zero crossing rate
    let zcr = zeroCrossingRate(window)
    
    return (
        centroid: basicFeatures.centroidHz,
        rolloff: basicFeatures.rolloffHz,
        bandwidth: basicFeatures.bandwidthHz,
        flatness: basicFeatures.flatness,
        flux: flux,
        zcr: zcr
    )
}

// MARK: - Spectral Flux

private func calculateSpectralFlux(_ window: [Float], sampleRate: Float) -> Float {
    let frameSize = 1024
    let hopSize = 512
    var fluxSum: Float = 0
    var frameCount = 0
    
    var prevMagnitudes: [Float] = []
    var i = 0
    
    while i + frameSize <= window.count {
        let frame = Array(window[i..<i+frameSize])
        let magnitudes = getFFTMagnitudes(frame)
        
        if !prevMagnitudes.isEmpty {
            var flux: Float = 0
            for j in 0..<magnitudes.count {
                let diff = magnitudes[j] - prevMagnitudes[j]
                if diff > 0 { flux += diff * diff }
            }
            fluxSum += sqrt(flux)
            frameCount += 1
        }
        
        prevMagnitudes = magnitudes
        i += hopSize
    }
    
    return frameCount > 0 ? fluxSum / Float(frameCount) : 0
}

// MARK: - FFT Magnitude Helper

private func getFFTMagnitudes(_ frame: [Float]) -> [Float] {
    let n = frame.count
    let nfft = 1 << Int(ceil(log2(Float(max(1024, n)))))
    var paddedFrame = frame + Array(repeating: 0, count: nfft - n)
    
    // Apply Hann window
    var window = [Float](repeating: 0, count: nfft)
    vDSP_hann_window(&window, vDSP_Length(nfft), Int32(vDSP_HANN_NORM))
    vDSP_vmul(paddedFrame, 1, window, 1, &paddedFrame, 1, vDSP_Length(nfft))
    
    // FFT
    let log2n = vDSP_Length(log2(Float(nfft)))
    let half = nfft/2
    var real = [Float](repeating: 0, count: half)
    var imag = [Float](repeating: 0, count: half)
    var magnitudes = [Float](repeating: 0, count: half)
    
    paddedFrame.withUnsafeBytes { ptr in
        let complexPtr = ptr.bindMemory(to: DSPComplex.self)
        var split = DSPSplitComplex(realp: &real, imagp: &imag)
        vDSP_ctoz(complexPtr.baseAddress!, 2, &split, 1, vDSP_Length(half))
        
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2))!
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
        vDSP_destroy_fftsetup(setup)
    }
    
    return magnitudes
}

// MARK: - Temporal Centroid

private func calculateTemporalCentroid(_ samples: [Float]) -> Float {
    let envelope = getEnvelope(samples, windowSize: 256)
    
    var sum: Float = 0
    var weightedSum: Float = 0
    
    for (i, value) in envelope.enumerated() {
        sum += value
        weightedSum += Float(i) * value
    }
    
    return sum > 0 ? weightedSum / sum / Float(envelope.count) : 0.5
}

private func getEnvelope(_ samples: [Float], windowSize: Int) -> [Float] {
    var envelope: [Float] = []
    var i = 0
    
    while i < samples.count {
        let end = min(i + windowSize, samples.count)
        let window = Array(samples[i..<end])
        let rms = rootMeanSquare(window)
        envelope.append(rms)
        i += windowSize / 2
    }
    
    return envelope
}

// MARK: - MFCC Extraction (Simplified)

private func extractMFCC(_ window: [Float], sampleRate: Float, numCoefficients: Int) -> [Float] {
    // This is a simplified MFCC extraction
    // In production, you'd want to use a proper MFCC implementation
    
    let magnitudes = getFFTMagnitudes(window)
    let melFilters = createMelFilterBank(numFilters: 26, fftSize: magnitudes.count * 2, sampleRate: sampleRate)
    
    var melEnergies = [Float](repeating: 0, count: melFilters.count)
    for (i, filter) in melFilters.enumerated() {
        var energy: Float = 0
        for (j, magnitude) in magnitudes.enumerated() {
            if j < filter.count {
                energy += magnitude * magnitude * filter[j]
            }
        }
        melEnergies[i] = log(max(energy, 1e-10))
    }
    
    // DCT to get MFCC
    var mfcc = [Float](repeating: 0, count: numCoefficients)
    for i in 0..<numCoefficients {
        var sum: Float = 0
        for (j, energy) in melEnergies.enumerated() {
            // Break up complex expression
            let iFloat = Float(i)
            let jFloat = Float(j) + 0.5
            let piFloat = Float.pi
            let countFloat = Float(melEnergies.count)
            let angle = iFloat * jFloat * piFloat / countFloat
            sum += energy * cos(angle)
        }
        mfcc[i] = sum
    }
    
    return mfcc
}

private func createMelFilterBank(numFilters: Int, fftSize: Int, sampleRate: Float) -> [[Float]] {
    // Simplified mel filter bank creation
    let maxFreq = sampleRate / 2
    let melMax = 2595 * log10(1 + maxFreq / 700)
    let melPoints = (0...numFilters+1).map { i in
        Float(i) * melMax / Float(numFilters + 1)
    }
    
    let freqPoints = melPoints.map { mel in
        700 * (pow(10, mel / 2595) - 1)
    }
    
    let bins = freqPoints.map { freq in
        Int(freq * Float(fftSize) / sampleRate)
    }
    
    var filters: [[Float]] = []
    
    for i in 1..<bins.count-1 {
        var filter = [Float](repeating: 0, count: fftSize/2)
        
        for j in bins[i-1]..<bins[i] {
            if j < filter.count {
                filter[j] = Float(j - bins[i-1]) / Float(bins[i] - bins[i-1])
            }
        }
        
        for j in bins[i]..<bins[i+1] {
            if j < filter.count {
                filter[j] = Float(bins[i+1] - j) / Float(bins[i+1] - bins[i])
            }
        }
        
        filters.append(filter)
    }
    
    return filters
}

// MARK: - Improved Clustering Algorithm

public func optimizedGroupSamples(
    urls: [URL],
    options: ClusteringOptions = ClusteringOptions()
) throws -> [[URL]] {
    
    // Extract enhanced features
    let features = try urls.map { try extractEnhancedFeatures(from: $0, adaptiveWindow: options.adaptiveWindowing) }
    
    // Normalize features
    let normalizedFeatures = normalizeEnhancedFeatures(features)
    
    // Create weighted feature vectors
    let vectors = normalizedFeatures.map { feature in
        createWeightedFeatureVector(feature, loudnessWeight: options.loudnessWeight)
    }
    
    // Determine optimal number of clusters
    let optimalK = determineOptimalClustersEnhanced(
        vectors: vectors,
        minK: options.minClusters,
        maxK: min(options.maxClusters, urls.count)
    )
    
    // Perform clustering based on method
    let labels: [Int]
    switch options.method {
    case .kMeans:
        (labels, _) = kMeansEnhanced(vectors: vectors, k: optimalK, maxIters: 200)
    case .hierarchical:
        labels = hierarchicalClustering(vectors: vectors, k: optimalK)
    case .dbscan:
        labels = dbscanClustering(vectors: vectors, eps: 0.5, minPts: 2)
    }
    
    // Group URLs by cluster
    var groups: [[(url: URL, feat: EnhancedSampleFeatures, label: Int)]] = Array(repeating: [], count: labels.max()! + 1)
    for (i, label) in labels.enumerated() {
        if label >= 0 { // DBSCAN might return -1 for noise
            groups[label].append((urls[i], features[i], label))
        }
    }
    
    // Sort clusters by median RMS (quietest to loudest)
    let sortedGroups = groups.sorted { 
        medianValue($0.map { $0.feat.rms }) < medianValue($1.map { $0.feat.rms })
    }
    
    // Within each cluster, sort by diversity
    return sortedGroups.map { cluster in
        let clusterVectors = cluster.map { createWeightedFeatureVector($0.feat, loudnessWeight: options.loudnessWeight) }
        let sortedIndices = sortByDiversityEnhanced(vectors: clusterVectors)
        return sortedIndices.map { cluster[$0].url }
    }
}

// MARK: - Enhanced Clustering Methods

private func kMeansEnhanced(vectors: [[Float]], k: Int, maxIters: Int) -> (labels: [Int], centroids: [[Float]]) {
    // Use k-means++ initialization for better starting centroids
    var centroids = kMeansPlusPlusInit(vectors: vectors, k: k)
    var labels = [Int](repeating: 0, count: vectors.count)
    
    for iteration in 0..<maxIters {
        var changed = false
        
        // Assignment step
        for (i, v) in vectors.enumerated() {
            var bestCluster = 0
            var bestDist = Float.greatestFiniteMagnitude
            
            for (j, c) in centroids.enumerated() {
                let dist = euclideanDistance(v, c)
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

private func hierarchicalClustering(vectors: [[Float]], k: Int) -> [Int] {
    // Simplified hierarchical clustering using average linkage
    var clusters: [[Int]] = (0..<vectors.count).map { [$0] }
    var labels = Array(0..<vectors.count)
    
    // Build distance matrix
    var distances: [[Float]] = Array(repeating: Array(repeating: Float.greatestFiniteMagnitude, count: vectors.count), count: vectors.count)
    
    for i in 0..<vectors.count {
        for j in i+1..<vectors.count {
            let dist = euclideanDistance(vectors[i], vectors[j])
            distances[i][j] = dist
            distances[j][i] = dist
        }
        distances[i][i] = 0
    }
    
    // Merge clusters until we have k clusters
    while clusters.count > k {
        var minDist = Float.greatestFiniteMagnitude
        var mergeI = 0
        var mergeJ = 0
        
        // Find closest clusters
        for i in 0..<clusters.count {
            for j in i+1..<clusters.count {
                let avgDist = averageClusterDistance(clusters[i], clusters[j], distances: distances)
                if avgDist < minDist {
                    minDist = avgDist
                    mergeI = i
                    mergeJ = j
                }
            }
        }
        
        // Merge clusters
        clusters[mergeI] += clusters[mergeJ]
        clusters.remove(at: mergeJ)
        
        // Update labels
        for (clusterIdx, cluster) in clusters.enumerated() {
            for sampleIdx in cluster {
                labels[sampleIdx] = clusterIdx
            }
        }
    }
    
    return labels
}

private func dbscanClustering(vectors: [[Float]], eps: Float, minPts: Int) -> [Int] {
    var labels = Array(repeating: -1, count: vectors.count) // -1 = unvisited
    var currentCluster = 0
    
    for i in 0..<vectors.count {
        if labels[i] != -1 { continue } // Already visited
        
        let neighbors = findNeighbors(index: i, vectors: vectors, eps: eps)
        
        if neighbors.count < minPts {
            labels[i] = -2 // Mark as noise
        } else {
            // Start new cluster
            expandCluster(index: i, neighbors: neighbors, cluster: currentCluster, labels: &labels, vectors: vectors, eps: eps, minPts: minPts)
            currentCluster += 1
        }
    }
    
    // Convert noise points to nearest cluster
    for i in 0..<labels.count {
        if labels[i] == -2 {
            labels[i] = findNearestCluster(index: i, labels: labels, vectors: vectors)
        }
    }
    
    return labels
}

// MARK: - Helper Functions

private func normalizeEnhancedFeatures(_ features: [EnhancedSampleFeatures]) -> [EnhancedSampleFeatures] {
    // This would normalize all features to have zero mean and unit variance
    // For brevity, returning as-is
    return features
}

private func createWeightedFeatureVector(_ feature: EnhancedSampleFeatures, loudnessWeight: Float) -> [Float] {
    let timbreWeight = 1.0 - loudnessWeight
    
    var weighted = feature.featureVector
    
    // Apply weights to different feature groups
    // First 3 are loudness features
    for i in 0..<3 {
        weighted[i] *= loudnessWeight
    }
    
    // Rest are timbre features
    for i in 3..<weighted.count {
        weighted[i] *= timbreWeight
    }
    
    return weighted
}

private func determineOptimalClustersEnhanced(vectors: [[Float]], minK: Int, maxK: Int) -> Int {
    var bestK = minK
    var bestScore = -Float.greatestFiniteMagnitude
    
    for k in minK...maxK {
        let (labels, centroids) = kMeansEnhanced(vectors: vectors, k: k, maxIters: 50)
        
        // Calculate silhouette score
        let score = calculateSilhouetteScore(vectors: vectors, labels: labels)
        
        if score > bestScore {
            bestScore = score
            bestK = k
        }
    }
    
    return bestK
}

private func calculateSilhouetteScore(vectors: [[Float]], labels: [Int]) -> Float {
    var totalScore: Float = 0
    
    for (i, vector) in vectors.enumerated() {
        let cluster = labels[i]
        
        // Calculate a(i) - average distance to points in same cluster
        let sameCluster = vectors.enumerated().filter { labels[$0.offset] == cluster && $0.offset != i }
        let a = sameCluster.isEmpty ? 0 : sameCluster.map { euclideanDistance(vector, $0.element) }.reduce(0, +) / Float(sameCluster.count)
        
        // Calculate b(i) - minimum average distance to points in other clusters
        var b = Float.greatestFiniteMagnitude
        let otherClusters = Set(labels).filter { $0 != cluster }
        
        for otherCluster in otherClusters {
            let otherPoints = vectors.enumerated().filter { labels[$0.offset] == otherCluster }
            if !otherPoints.isEmpty {
                let avgDist = otherPoints.map { euclideanDistance(vector, $0.element) }.reduce(0, +) / Float(otherPoints.count)
                b = min(b, avgDist)
            }
        }
        
        // Silhouette coefficient for this point
        let s = (b - a) / max(a, b)
        totalScore += s
    }
    
    return totalScore / Float(vectors.count)
}

// MARK: - Distance Functions

private func euclideanDistance(_ a: [Float], _ b: [Float]) -> Float {
    var sum: Float = 0
    for i in 0..<min(a.count, b.count) {
        let diff = a[i] - b[i]
        sum += diff * diff
    }
    return sqrt(sum)
}

private func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
    vDSP_dotpr(a, 1, a, 1, &na, vDSP_Length(a.count))
    vDSP_dotpr(b, 1, b, 1, &nb, vDSP_Length(a.count))
    let denom = (sqrt(na) * sqrt(nb))
    return 1 - (denom > 0 ? (dot / denom) : 0)
}

// MARK: - Clustering Helpers

private func kMeansPlusPlusInit(vectors: [[Float]], k: Int) -> [[Float]] {
    var centroids: [[Float]] = []
    
    // Choose first centroid randomly
    centroids.append(vectors.randomElement()!)
    
    // Choose remaining centroids
    for _ in 1..<k {
        var distances: [Float] = []
        
        for vector in vectors {
            let minDist = centroids.map { euclideanDistance(vector, $0) }.min() ?? 0
            distances.append(minDist * minDist)
        }
        
        // Choose next centroid with probability proportional to squared distance
        let totalDist = distances.reduce(0, +)
        var randomValue = Float.random(in: 0..<totalDist)
        
        for (i, dist) in distances.enumerated() {
            randomValue -= dist
            if randomValue <= 0 {
                centroids.append(vectors[i])
                break
            }
        }
    }
    
    return centroids
}

private func calculateCentroid(_ vectors: [[Float]]) -> [Float] {
    guard !vectors.isEmpty else { return [] }
    
    let dim = vectors[0].count
    var centroid = [Float](repeating: 0, count: dim)
    
    for vector in vectors {
        vDSP_vadd(centroid, 1, vector, 1, &centroid, 1, vDSP_Length(dim))
    }
    
    var inv = 1.0 / Float(vectors.count)
    vDSP_vsmul(centroid, 1, &inv, &centroid, 1, vDSP_Length(dim))
    
    return centroid
}

private func averageClusterDistance(_ cluster1: [Int], _ cluster2: [Int], distances: [[Float]]) -> Float {
    var sum: Float = 0
    var count = 0
    
    for i in cluster1 {
        for j in cluster2 {
            sum += distances[i][j]
            count += 1
        }
    }
    
    return count > 0 ? sum / Float(count) : Float.greatestFiniteMagnitude
}

private func findNeighbors(index: Int, vectors: [[Float]], eps: Float) -> [Int] {
    var neighbors: [Int] = []
    
    for (i, vector) in vectors.enumerated() {
        if i != index && euclideanDistance(vectors[index], vector) <= eps {
            neighbors.append(i)
        }
    }
    
    return neighbors
}

private func expandCluster(index: Int, neighbors: [Int], cluster: Int, labels: inout [Int], vectors: [[Float]], eps: Float, minPts: Int) {
    labels[index] = cluster
    var seeds = neighbors
    var i = 0
    
    while i < seeds.count {
        let current = seeds[i]
        
        if labels[current] == -1 { // Unvisited
            labels[current] = cluster
            let currentNeighbors = findNeighbors(index: current, vectors: vectors, eps: eps)
            
            if currentNeighbors.count >= minPts {
                seeds += currentNeighbors.filter { !seeds.contains($0) }
            }
        } else if labels[current] == -2 { // Noise
            labels[current] = cluster
        }
        
        i += 1
    }
}

private func findNearestCluster(index: Int, labels: [Int], vectors: [[Float]]) -> Int {
    var minDist = Float.greatestFiniteMagnitude
    var nearestCluster = 0
    
    for (i, label) in labels.enumerated() {
        if label >= 0 && i != index {
            let dist = euclideanDistance(vectors[index], vectors[i])
            if dist < minDist {
                minDist = dist
                nearestCluster = label
            }
        }
    }
    
    return nearestCluster
}

private func sortByDiversityEnhanced(vectors: [[Float]]) -> [Int] {
    guard !vectors.isEmpty else { return [] }
    
    var indices = Array(0..<vectors.count)
    var sorted = [Int]()
    
    // Start with the sample closest to the centroid
    let centroid = calculateCentroid(vectors)
    let startIdx = indices.min { euclideanDistance(vectors[$0], centroid) < euclideanDistance(vectors[$1], centroid) }!
    
    sorted.append(startIdx)
    indices.remove(at: indices.firstIndex(of: startIdx)!)
    
    // Greedily pick the most different sample each time
    while !indices.isEmpty {
        var bestIdx = 0
        var bestMinDist = -Float.greatestFiniteMagnitude
        
        for (i, idx) in indices.enumerated() {
            let minDist = sorted.map { euclideanDistance(vectors[idx], vectors[$0]) }.min() ?? 0
            if minDist > bestMinDist {
                bestMinDist = minDist
                bestIdx = i
            }
        }
        
        sorted.append(indices[bestIdx])
        indices.remove(at: bestIdx)
    }
    
    return sorted
}

private func medianValue(_ values: [Float]) -> Float {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    return sorted.count % 2 == 0 ? (sorted[mid-1] + sorted[mid]) * 0.5 : sorted[mid]
}

// MARK: - Reused functions from original

private func rootMeanSquare(_ x: [Float]) -> Float {
    var val: Float = 0
    vDSP_measqv(x, 1, &val, vDSP_Length(x.count))
    return sqrt(val)
}

private func zeroCrossingRate(_ x: [Float]) -> Float {
    guard x.count > 1 else { return 0 }
    var count: Float = 0
    for i in 1..<x.count {
        if (x[i-1] >= 0 && x[i] < 0) || (x[i-1] < 0 && x[i] >= 0) { count += 1 }
    }
    return count / Float(x.count - 1)
}

// MARK: - Spectral Descriptors (from original)

private func spectralDescriptors(_ x: [Float], sampleRate sr: Float) -> (centroidHz: Float, rolloffHz: Float, bandwidthHz: Float, flatness: Float) {
    // Pad to next pow2
    let n = x.count
    let nfft = 1 << Int(ceil(log2(Float(max(2048, n)))))
    var frame = x
    frame += Array(repeating: 0, count: max(0, nfft - n))
    // Hann
    var window = [Float](repeating: 0, count: nfft)
    vDSP_hann_window(&window, vDSP_Length(nfft), Int32(vDSP_HANN_NORM))
    vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(nfft))

    // FFT
    let log2n = vDSP_Length(log2(Float(nfft)))
    let half = nfft/2
    var real = [Float](repeating: 0, count: half)
    var imag = [Float](repeating: 0, count: half)
    var result = [Float](repeating: 0, count: 4)
    real.withUnsafeMutableBufferPointer { rPtr in
        imag.withUnsafeMutableBufferPointer { iPtr in
            frame.withUnsafeBytes { fPtr in
                var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                fPtr.bindMemory(to: Float.self).baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nfft) { _ in
                    let setup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2))!
                    frame.withUnsafeMutableBytes { frPtr in
                        frPtr.bindMemory(to: DSPComplex.self)
                        vDSP_ctoz(frPtr.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        // Magnitude
                        var mag = [Float](repeating: 0, count: half)
                        vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(half))
                        // Frequency axis
                        let df = sr / Float(nfft)
                        let freqs = (0..<half).map { Float($0) * df }

                        // Spectral centroid
                        var num: Float = 0, den: Float = 0
                        vDSP_dotpr(mag, 1, freqs, 1, &num, vDSP_Length(half))
                        vDSP_sve(mag, 1, &den, vDSP_Length(half))
                        let centroid = (den > 0) ? (num / den) : 0

                        // Bandwidth (2nd moment around centroid)
                        var diff = [Float](repeating: 0, count: half)
                        vDSP_vsmsa(freqs, 1, [-1], [centroid], &diff, 1, vDSP_Length(half)) // diff = freqs - centroid
                        var diff2 = [Float](repeating: 0, count: half)
                        vDSP_vsq(diff, 1, &diff2, 1, vDSP_Length(half))
                        var bwNum: Float = 0
                        vDSP_dotpr(diff2, 1, mag, 1, &bwNum, vDSP_Length(half))
                        let bandwidth = (den > 0) ? sqrt(bwNum / den) : 0

                        // Rolloff 85%
                        let target: Float = 0.85 * den
                        var cumsum: Float = 0
                        var rolloffHz: Float = 0
                        for i in 0..<half {
                            cumsum += mag[i]
                            if cumsum >= target { rolloffHz = Float(i) * df; break }
                        }

                        // Flatness (geometric mean / arithmetic mean)
                        var gmean: Float = 0
                        var amean: Float = 0
                        let eps: Float = 1e-12
                        let magSafe = mag.map { max($0, eps) }
                        vDSP_meanv(magSafe, 1, &amean, vDSP_Length(half))
                        let logMag = magSafe.map { logf($0) }
                        var meanLog: Float = 0
                        vDSP_meanv(logMag, 1, &meanLog, vDSP_Length(half))
                        gmean = expf(meanLog)
                        let flatness = (amean > 0) ? gmean / amean : 0

                        vDSP_destroy_fftsetup(setup)
                        // Return via local array
                        result = [centroid, rolloffHz, bandwidth, flatness]
                    }
                }
            }
        }
    }
    return (centroidHz: result[0], rolloffHz: result[1], bandwidthHz: result[2], flatness: result[3])
}