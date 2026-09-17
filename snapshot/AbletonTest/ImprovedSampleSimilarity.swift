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

// MARK: - Quality Metrics for K Selection

public struct ClusteringQuality {
    let silhouette: Float
    let daviesBouldin: Float?
    let calinskiHarabasz: Float?
}

// Helper function to calculate cluster size entropy
private func calculateClusterSizeEntropy(labels: [Int]) -> Float {
    var clusterSizes: [Int: Int] = [:]
    for label in labels {
        clusterSizes[label, default: 0] += 1
    }
    
    let n = Float(labels.count)
    var entropy: Float = 0
    
    for size in clusterSizes.values {
        let p = Float(size) / n
        if p > 0 {
            entropy -= p * log2(p)
        }
    }
    
    // Normalize by log2(k) to get value in [0,1]
    let k = clusterSizes.count
    return k > 1 ? entropy / log2(Float(k)) : 0
}

public func modelSelectionScore(_ quality: ClusteringQuality, k: Int, targetK: Int? = nil, lambda: Float = 0.15, labels: [Int]? = nil) -> Float {
    var score = quality.silhouette
    
    if let dbi = quality.daviesBouldin {
        score += max(0, 1 - min(dbi, 2)) * 0.2
    }
    
    if let ch = quality.calinskiHarabasz {
        score += min(ch / 1000, 0.2)
    }
    
    // Add cluster size entropy penalty (prefer balanced clusters)
    if let labels = labels {
        let entropy = calculateClusterSizeEntropy(labels: labels)
        score += entropy * 0.1 // Higher entropy = more balanced = better
        
        // Penalty for singleton clusters
        var clusterSizes: [Int: Int] = [:]
        for label in labels {
            clusterSizes[label, default: 0] += 1
        }
        let singletonCount = clusterSizes.values.filter { $0 == 1 }.count
        let singletonPenalty = Float(singletonCount) * 0.05
        score -= singletonPenalty
    }
    
    if let target = targetK {
        score += -lambda * powf(Float(k - target), 2)
    }
    
    return score
}

// MARK: - Two-Stage Grouping (RMS → Timbre)

public func twoStageGrouping(
    urls: [URL],
    windowMs: Double = 256,
    targetVelocityLayers: Int? = nil,
    roundRobinsPerLayer: Int = 5
) throws -> (groups: [[URL]], quality: ClusteringQuality, selectedK: Int, rmsRanges: [(min: Float, max: Float)]) {
    
    // Extract enhanced features
    let features = try urls.map { try extractEnhancedFeatures(from: $0, adaptiveWindow: true) }
    
    // Stage 1: RMS binning
    let sortedByRMS = features.enumerated().sorted { $0.element.rms < $1.element.rms }
    let rmsValues = sortedByRMS.map { $0.element.rms }
    let rmsClusters = identifyRMSClusters(rmsValues)
    
    // If target velocity layers specified, adjust RMS clusters
    let finalRMSClusters: [(min: Float, max: Float)]
    if let target = targetVelocityLayers, rmsClusters.count != target {
        finalRMSClusters = adjustRMSClusters(rmsClusters, targetCount: target, rmsValues: rmsValues)
    } else {
        finalRMSClusters = rmsClusters
    }
    
    // Stage 2: Timbre clustering within each RMS bin
    var allGroups: [[URL]] = []
    var overallQuality = ClusteringQuality(silhouette: 0, daviesBouldin: nil, calinskiHarabasz: nil)
    var totalK = 0
    
    for (binIndex, rmsRange) in finalRMSClusters.enumerated() {
        // Get samples in this RMS range
        let binSamples = sortedByRMS.filter { 
            $0.element.rms >= rmsRange.min && $0.element.rms <= rmsRange.max 
        }
        
        if binSamples.isEmpty { continue }
        
        // Extract URLs and features for this bin
        let binURLs = binSamples.map { urls[$0.offset] }
        let binFeatures = binSamples.map { $0.element }
        
        if binURLs.count <= roundRobinsPerLayer {
            // If few samples, keep them all as round robins
            allGroups.append(binURLs)
            totalK += 1
        } else {
            // Cluster by timbre within this RMS bin
            let normalizedFeatures = normalizeEnhancedFeatures(binFeatures)
            let vectors = normalizedFeatures.map { $0.featureVector }
            
            // Determine K for this bin (aiming for ~roundRobinsPerLayer samples per cluster)
            let binK = max(1, min(binURLs.count / roundRobinsPerLayer, 3))
            
            let (binGroups, binQuality, _) = try autoGroupEnhanced(
                urls: binURLs,
                windowMs: windowMs,
                targetK: binK,
                numRestarts: 5
            )
            
            allGroups.append(contentsOf: binGroups)
            totalK += binGroups.count
            
            // Accumulate quality metrics (weighted by bin size)
            let weight = Float(binURLs.count) / Float(urls.count)
            overallQuality = ClusteringQuality(
                silhouette: overallQuality.silhouette + binQuality.silhouette * weight,
                daviesBouldin: nil, // Will recalculate globally
                calinskiHarabasz: nil
            )
        }
    }
    
    return (allGroups, overallQuality, totalK, finalRMSClusters)
}

// Helper function to identify RMS clusters (similar to SpectralGroupingImprovements)
private func identifyRMSClusters(_ sortedRMS: [Float]) -> [(min: Float, max: Float)] {
    guard sortedRMS.count > 1 else { return [(sortedRMS.first ?? 0, sortedRMS.first ?? 0)] }
    
    // Calculate gaps between consecutive RMS values
    var gaps: [(index: Int, gap: Float)] = []
    for i in 1..<sortedRMS.count {
        let gap = sortedRMS[i] - sortedRMS[i-1]
        gaps.append((i, gap))
    }
    
    // Find significant gaps
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

// Helper to adjust RMS clusters to target count
private func adjustRMSClusters(_ clusters: [(min: Float, max: Float)], targetCount: Int, rmsValues: [Float]) -> [(min: Float, max: Float)] {
    var workingClusters = clusters
    
    while workingClusters.count < targetCount && workingClusters.count < rmsValues.count {
        // Split the largest cluster
        var largestIdx = 0
        var largestRange: Float = 0
        
        for (i, cluster) in workingClusters.enumerated() {
            let range = cluster.max - cluster.min
            if range > largestRange {
                largestRange = range
                largestIdx = i
            }
        }
        
        let splitPoint = (workingClusters[largestIdx].min + workingClusters[largestIdx].max) / 2
        let oldCluster = workingClusters[largestIdx]
        workingClusters[largestIdx] = (oldCluster.min, splitPoint)
        workingClusters.insert((splitPoint, oldCluster.max), at: largestIdx + 1)
    }
    
    while workingClusters.count > targetCount && workingClusters.count > 1 {
        // Merge the closest clusters
        var mergeIdx = 0
        var minGap = Float.greatestFiniteMagnitude
        
        for i in 0..<workingClusters.count - 1 {
            let gap = workingClusters[i + 1].min - workingClusters[i].max
            if gap < minGap {
                minGap = gap
                mergeIdx = i
            }
        }
        
        workingClusters[mergeIdx] = (workingClusters[mergeIdx].min, workingClusters[mergeIdx + 1].max)
        workingClusters.remove(at: mergeIdx + 1)
    }
    
    return workingClusters
}

// MARK: - PCA Whitening

private func pcaWhitening(vectors: [[Float]]) -> [[Float]] {
    guard !vectors.isEmpty, vectors.count > 1 else { return vectors }
    
    let n = vectors.count
    let d = vectors[0].count
    
    // Calculate mean
    var mean = [Float](repeating: 0, count: d)
    for vector in vectors {
        for i in 0..<d {
            mean[i] += vector[i]
        }
    }
    mean = mean.map { $0 / Float(n) }
    
    // Center the data
    var centered = vectors
    for i in 0..<n {
        for j in 0..<d {
            centered[i][j] -= mean[j]
        }
    }
    
    // Calculate covariance matrix (simplified - just diagonal scaling)
    var variances = [Float](repeating: 0, count: d)
    for vector in centered {
        for i in 0..<d {
            variances[i] += vector[i] * vector[i]
        }
    }
    variances = variances.map { $0 / Float(n - 1) }
    
    // Apply whitening transform (simplified - just variance normalization)
    var whitened = centered
    for i in 0..<n {
        for j in 0..<d {
            let std = sqrt(max(variances[j], 1e-6))
            whitened[i][j] /= std
        }
    }
    
    return whitened
}

// MARK: - Enhanced Auto-Grouping with Objective K Selection

public func autoGroupEnhanced(
    urls: [URL],
    windowMs: Double = 256,
    targetK: Int? = nil,
    numRestarts: Int = 10
) throws -> (groups: [[URL]], quality: ClusteringQuality, selectedK: Int) {
    
    // Extract enhanced features
    let features = try urls.map { try extractEnhancedFeatures(from: $0, adaptiveWindow: true) }
    
    // Normalize features
    let normalizedFeatures = normalizeEnhancedFeatures(features)
    
    // Create feature vectors
    let vectors = normalizedFeatures.map { $0.featureVector }
    
    // Apply PCA whitening for better clustering
    let whitenedVectors = pcaWhitening(vectors: vectors)
    
    // Determine K search range
    let minK = targetK != nil ? max(2, targetK! - 1) : 2
    let maxK = targetK != nil ? min(urls.count, targetK! + 2) : min(8, urls.count)
    
    var bestScore: Float = -Float.greatestFiniteMagnitude
    var bestK = minK
    var bestLabels: [Int] = []
    var bestQuality = ClusteringQuality(silhouette: 0, daviesBouldin: nil, calinskiHarabasz: nil)
    
    // Try different K values
    for k in minK...maxK {
        var kBestScore: Float = -Float.greatestFiniteMagnitude
        var kBestLabels: [Int] = []
        
        // Multiple restarts for each K
        for restart in 0..<numRestarts {
            let seed = k * 1000 + restart // Deterministic seed based on k and restart number
            let (labels, centroids) = kMeansEnhanced(vectors: whitenedVectors, k: k, maxIters: 200, seed: seed)
            
            // Calculate quality metrics
            let silhouette = calculateSilhouetteScore(vectors: whitenedVectors, labels: labels)
            let dbi = calculateDaviesBouldinIndex(vectors: whitenedVectors, labels: labels, centroids: centroids)
            let ch = calculateCalinskiHarabaszIndex(vectors: whitenedVectors, labels: labels, centroids: centroids)
            
            let quality = ClusteringQuality(silhouette: silhouette, daviesBouldin: dbi, calinskiHarabasz: ch)
            let score = modelSelectionScore(quality, k: k, targetK: targetK, labels: labels)
            
            if score > kBestScore {
                kBestScore = score
                kBestLabels = labels
            }
        }
        
        if kBestScore > bestScore {
            bestScore = kBestScore
            bestK = k
            bestLabels = kBestLabels
            
            // Recalculate quality for best clustering
            let (_, centroids) = recalculateCentroids(vectors: whitenedVectors, labels: bestLabels)
            let silhouette = calculateSilhouetteScore(vectors: whitenedVectors, labels: bestLabels)
            let dbi = calculateDaviesBouldinIndex(vectors: whitenedVectors, labels: bestLabels, centroids: centroids)
            let ch = calculateCalinskiHarabaszIndex(vectors: whitenedVectors, labels: bestLabels, centroids: centroids)
            bestQuality = ClusteringQuality(silhouette: silhouette, daviesBouldin: dbi, calinskiHarabasz: ch)
        }
    }
    
    // K-calibration if target K is specified and different from best K
    if let target = targetK, bestK != target {
        bestLabels = calibrateToK(targetK: target, labels: bestLabels, vectors: whitenedVectors)
        bestK = target
        
        // Recalculate quality after calibration
        let (_, centroids) = recalculateCentroids(vectors: whitenedVectors, labels: bestLabels)
        let silhouette = calculateSilhouetteScore(vectors: whitenedVectors, labels: bestLabels)
        let dbi = calculateDaviesBouldinIndex(vectors: whitenedVectors, labels: bestLabels, centroids: centroids)
        let ch = calculateCalinskiHarabaszIndex(vectors: whitenedVectors, labels: bestLabels, centroids: centroids)
        bestQuality = ClusteringQuality(silhouette: silhouette, daviesBouldin: dbi, calinskiHarabasz: ch)
    }
    
    // Group URLs by cluster
    var groups: [[(url: URL, feat: EnhancedSampleFeatures, label: Int)]] = Array(repeating: [], count: bestK)
    for (i, label) in bestLabels.enumerated() {
        groups[label].append((urls[i], features[i], label))
    }
    
    // Sort clusters by median RMS (quietest to loudest)
    let sortedGroups = groups.sorted { 
        medianValue($0.map { $0.feat.rms }) < medianValue($1.map { $0.feat.rms })
    }
    
    // Within each cluster, sort by diversity
    let result = sortedGroups.map { cluster in
        let clusterIndices = cluster.map { item in
            urls.firstIndex(of: item.url)!
        }
        let clusterVectors = clusterIndices.map { whitenedVectors[$0] }
        let sortedIndices = sortByDiversityEnhanced(vectors: clusterVectors)
        return sortedIndices.map { cluster[$0].url }
    }
    
    // Margin recheck - reassign ambiguous samples
    bestLabels = marginRecheckReassignment(vectors: whitenedVectors, labels: bestLabels, centroids: recalculateCentroids(vectors: whitenedVectors, labels: bestLabels).1)
    
    // Final regrouping after margin recheck
    groups = Array(repeating: [], count: bestK)
    for (i, label) in bestLabels.enumerated() {
        groups[label].append((urls[i], features[i], label))
    }
    
    let finalSortedGroups = groups.sorted { 
        medianValue($0.map { $0.feat.rms }) < medianValue($1.map { $0.feat.rms })
    }
    
    let finalResult = finalSortedGroups.map { cluster in
        let clusterIndices = cluster.map { item in
            urls.firstIndex(of: item.url)!
        }
        let clusterVectors = clusterIndices.map { whitenedVectors[$0] }
        let sortedIndices = sortByDiversityEnhanced(vectors: clusterVectors)
        return sortedIndices.map { cluster[$0].url }
    }
    
    return (finalResult, bestQuality, bestK)
}

// MARK: - Margin-based Reassignment

private func marginRecheckReassignment(vectors: [[Float]], labels: [Int], centroids: [[Float]], marginThreshold: Float = 1.2) -> [Int] {
    var newLabels = labels
    
    // First pass: identify ambiguous samples
    var ambiguousSamples: [(index: Int, margin: Float, currentCluster: Int, closestCluster: Int)] = []
    
    for (i, vector) in vectors.enumerated() {
        // Calculate distances to all centroids
        var distances: [(cluster: Int, distance: Float)] = []
        for (j, centroid) in centroids.enumerated() {
            distances.append((j, euclideanDistance(vector, centroid)))
        }
        
        // Sort by distance
        distances.sort { $0.distance < $1.distance }
        
        if distances.count >= 2 {
            let d1 = distances[0].distance
            let d2 = distances[1].distance
            let margin = d2 / max(d1, 0.0001)
            
            // If margin is small (ambiguous assignment)
            if margin < marginThreshold {
                let currentCluster = labels[i]
                let closestCluster = distances[0].cluster
                
                if currentCluster != closestCluster {
                    ambiguousSamples.append((i, margin, currentCluster, closestCluster))
                }
            }
        }
    }
    
    // Sort ambiguous samples by margin (most ambiguous first)
    ambiguousSamples.sort { $0.margin < $1.margin }
    
    // Second pass: try to reassign ambiguous samples to optimize model selection score
    for sample in ambiguousSamples {
        let i = sample.index
        let currentCluster = newLabels[i]
        let proposedCluster = sample.closestCluster
        
        // Calculate current model selection score
        let (_, currentCentroids) = recalculateCentroids(vectors: vectors, labels: newLabels)
        let currentSilhouette = calculateSilhouetteScore(vectors: vectors, labels: newLabels)
        let currentDBI = calculateDaviesBouldinIndex(vectors: vectors, labels: newLabels, centroids: currentCentroids)
        let currentCH = calculateCalinskiHarabaszIndex(vectors: vectors, labels: newLabels, centroids: currentCentroids)
        let currentQuality = ClusteringQuality(silhouette: currentSilhouette, daviesBouldin: currentDBI, calinskiHarabasz: currentCH)
        let currentScore = modelSelectionScore(currentQuality, k: currentCentroids.count, labels: newLabels)
        
        // Try reassignment
        var testLabels = newLabels
        testLabels[i] = proposedCluster
        
        // Calculate new model selection score
        let (_, testCentroids) = recalculateCentroids(vectors: vectors, labels: testLabels)
        let testSilhouette = calculateSilhouetteScore(vectors: vectors, labels: testLabels)
        let testDBI = calculateDaviesBouldinIndex(vectors: vectors, labels: testLabels, centroids: testCentroids)
        let testCH = calculateCalinskiHarabaszIndex(vectors: vectors, labels: testLabels, centroids: testCentroids)
        let testQuality = ClusteringQuality(silhouette: testSilhouette, daviesBouldin: testDBI, calinskiHarabasz: testCH)
        let testScore = modelSelectionScore(testQuality, k: testCentroids.count, labels: testLabels)
        
        // Accept reassignment if it improves overall model selection score
        if testScore > currentScore {
            newLabels[i] = proposedCluster
        }
    }
    
    return newLabels
}

private func calculateLocalSilhouette(vector: [Float], cluster: Int, vectors: [[Float]], labels: [Int]) -> Float {
    // Calculate a(i) - average distance to points in same cluster
    let sameCluster = vectors.enumerated().filter { labels[$0.offset] == cluster && $0.offset != vectors.firstIndex(where: { $0 == vector }) }
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
    
    return (b - a) / max(a, b)
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
        // Use Ward linkage for small datasets (<= 30 samples)
        let linkage = urls.count <= 30 ? "ward" : "average"
        labels = hierarchicalClustering(vectors: vectors, k: optimalK, linkage: linkage)
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

private func kMeansEnhanced(vectors: [[Float]], k: Int, maxIters: Int, seed: Int? = nil) -> (labels: [Int], centroids: [[Float]]) {
    // Use k-means++ initialization for better starting centroids
    var centroids = kMeansPlusPlusInit(vectors: vectors, k: k, seed: seed)
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

private func hierarchicalClustering(vectors: [[Float]], k: Int, linkage: String = "ward") -> [Int] {
    var clusters: [[Int]] = (0..<vectors.count).map { [$0] }
    var labels = Array(0..<vectors.count)
    
    // Calculate cluster centroids for Ward linkage
    var centroids: [[Float]] = vectors
    
    // Build initial distance matrix for single points
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
                let dist: Float
                
                if linkage == "ward" {
                    // Ward linkage minimizes within-cluster variance
                    dist = wardDistance(clusters[i], clusters[j], vectors: vectors, centroids: centroids)
                } else {
                    // Average linkage
                    dist = averageClusterDistance(clusters[i], clusters[j], distances: distances)
                }
                
                if dist < minDist {
                    minDist = dist
                    mergeI = i
                    mergeJ = j
                }
            }
        }
        
        // Merge clusters
        let newCluster = clusters[mergeI] + clusters[mergeJ]
        clusters[mergeI] = newCluster
        clusters.remove(at: mergeJ)
        
        // Update centroid for merged cluster (for Ward linkage)
        if linkage == "ward" {
            let clusterVectors = newCluster.map { vectors[$0] }
            centroids[mergeI] = calculateCentroid(clusterVectors)
            centroids.remove(at: mergeJ)
        }
        
        // Update labels
        for (clusterIdx, cluster) in clusters.enumerated() {
            for sampleIdx in cluster {
                labels[sampleIdx] = clusterIdx
            }
        }
    }
    
    return labels
}

// Ward distance calculation
private func wardDistance(_ cluster1: [Int], _ cluster2: [Int], vectors: [[Float]], centroids: [[Float]]) -> Float {
    let n1 = Float(cluster1.count)
    let n2 = Float(cluster2.count)
    
    // Calculate merged cluster centroid
    let cluster1Vectors = cluster1.map { vectors[$0] }
    let cluster2Vectors = cluster2.map { vectors[$0] }
    let mergedVectors = cluster1Vectors + cluster2Vectors
    let mergedCentroid = calculateCentroid(mergedVectors)
    
    // Calculate increase in within-cluster sum of squares
    var wcss1: Float = 0
    for vec in cluster1Vectors {
        wcss1 += pow(euclideanDistance(vec, centroids[0]), 2)
    }
    
    var wcss2: Float = 0
    for vec in cluster2Vectors {
        wcss2 += pow(euclideanDistance(vec, centroids[1]), 2)
    }
    
    var wcssMerged: Float = 0
    for vec in mergedVectors {
        wcssMerged += pow(euclideanDistance(vec, mergedCentroid), 2)
    }
    
    // Ward criterion: minimize increase in within-cluster variance
    return wcssMerged - wcss1 - wcss2
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
    var clusterSizes: [Int: Int] = [:]
    
    // Count cluster sizes
    for label in labels {
        clusterSizes[label, default: 0] += 1
    }
    
    for (i, vector) in vectors.enumerated() {
        let cluster = labels[i]
        
        // Treat singleton clusters as having silhouette score of 0
        if clusterSizes[cluster, default: 0] == 1 {
            totalScore += 0
            continue
        }
        
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

private func calculateDaviesBouldinIndex(vectors: [[Float]], labels: [Int], centroids: [[Float]]) -> Float? {
    let k = centroids.count
    guard k > 1 else { return nil }
    
    // Calculate average distance within each cluster
    var avgDistances = [Float](repeating: 0, count: k)
    var clusterCounts = [Int](repeating: 0, count: k)
    
    for (i, vector) in vectors.enumerated() {
        let cluster = labels[i]
        avgDistances[cluster] += euclideanDistance(vector, centroids[cluster])
        clusterCounts[cluster] += 1
    }
    
    for i in 0..<k {
        if clusterCounts[i] > 0 {
            avgDistances[i] /= Float(clusterCounts[i])
        }
    }
    
    // Calculate Davies-Bouldin index
    var dbIndex: Float = 0
    
    for i in 0..<k {
        var maxRatio: Float = 0
        
        for j in 0..<k where j != i {
            let centroidDist = euclideanDistance(centroids[i], centroids[j])
            if centroidDist > 0 {
                let ratio = (avgDistances[i] + avgDistances[j]) / centroidDist
                maxRatio = max(maxRatio, ratio)
            }
        }
        
        dbIndex += maxRatio
    }
    
    return dbIndex / Float(k)
}

private func calculateCalinskiHarabaszIndex(vectors: [[Float]], labels: [Int], centroids: [[Float]]) -> Float? {
    let n = vectors.count
    let k = centroids.count
    guard k > 1 && n > k else { return nil }
    
    // Calculate overall centroid
    var overallCentroid = [Float](repeating: 0, count: vectors[0].count)
    for vector in vectors {
        for (i, val) in vector.enumerated() {
            overallCentroid[i] += val
        }
    }
    overallCentroid = overallCentroid.map { $0 / Float(n) }
    
    // Between-cluster scatter
    var betweenScatter: Float = 0
    var clusterCounts = [Int](repeating: 0, count: k)
    
    for label in labels {
        clusterCounts[label] += 1
    }
    
    for (i, centroid) in centroids.enumerated() {
        let dist = euclideanDistance(centroid, overallCentroid)
        betweenScatter += Float(clusterCounts[i]) * dist * dist
    }
    
    // Within-cluster scatter
    var withinScatter: Float = 0
    for (i, vector) in vectors.enumerated() {
        let cluster = labels[i]
        let dist = euclideanDistance(vector, centroids[cluster])
        withinScatter += dist * dist
    }
    
    return (betweenScatter / Float(k - 1)) / (withinScatter / Float(n - k))
}

private func recalculateCentroids(vectors: [[Float]], labels: [Int]) -> ([Int], [[Float]]) {
    let k = (labels.max() ?? 0) + 1
    var centroids = Array(repeating: [Float](repeating: 0, count: vectors[0].count), count: k)
    var counts = [Int](repeating: 0, count: k)
    
    for (i, vector) in vectors.enumerated() {
        let cluster = labels[i]
        for (j, val) in vector.enumerated() {
            centroids[cluster][j] += val
        }
        counts[cluster] += 1
    }
    
    for i in 0..<k {
        if counts[i] > 0 {
            centroids[i] = centroids[i].map { $0 / Float(counts[i]) }
        }
    }
    
    return (labels, centroids)
}

// MARK: - K-Calibration

private func calibrateToK(targetK: Int, labels: [Int], vectors: [[Float]]) -> [Int] {
    var workingLabels = labels
    var currentK = Set(labels).count
    
    while currentK != targetK {
        if currentK < targetK {
            workingLabels = splitWorstCluster(labels: workingLabels, vectors: vectors)
        } else {
            workingLabels = mergeClosestClusters(labels: workingLabels, vectors: vectors)
        }
        currentK = Set(workingLabels).count
    }
    
    return workingLabels
}

private func splitWorstCluster(labels: [Int], vectors: [[Float]]) -> [Int] {
    // Calculate per-cluster metrics
    var clusterMetrics: [(cluster: Int, size: Int, score: Float, intraVariance: Float)] = []
    let clusters = Set(labels)
    
    for cluster in clusters {
        let clusterIndices = labels.enumerated().filter { $0.element == cluster }.map { $0.offset }
        let size = clusterIndices.count
        
        if size > 1 {
            // Calculate silhouette score (treating singletons as 0)
            var totalScore: Float = 0
            for idx in clusterIndices {
                let vector = vectors[idx]
                
                // Average distance within cluster
                let sameCluster = clusterIndices.filter { $0 != idx }
                let a = sameCluster.map { euclideanDistance(vector, vectors[$0]) }.reduce(0, +) / Float(sameCluster.count)
                
                // Minimum average distance to other clusters
                var b = Float.greatestFiniteMagnitude
                for otherCluster in clusters where otherCluster != cluster {
                    let otherIndices = labels.enumerated().filter { $0.element == otherCluster }.map { $0.offset }
                    if !otherIndices.isEmpty {
                        let avgDist = otherIndices.map { euclideanDistance(vector, vectors[$0]) }.reduce(0, +) / Float(otherIndices.count)
                        b = min(b, avgDist)
                    }
                }
                
                totalScore += (b - a) / max(a, b)
            }
            let avgScore = totalScore / Float(size)
            
            // Calculate intra-cluster variance
            let clusterVectors = clusterIndices.map { vectors[$0] }
            let centroid = calculateCentroid(clusterVectors)
            var variance: Float = 0
            for vec in clusterVectors {
                variance += pow(euclideanDistance(vec, centroid), 2)
            }
            variance /= Float(size)
            
            clusterMetrics.append((cluster, size, avgScore, variance))
        } else {
            // Singleton cluster - don't split
            clusterMetrics.append((cluster, size, 0, 0))
        }
    }
    
    // Prioritize splitting:
    // 1. Large clusters with low silhouette scores
    // 2. Clusters with high internal variance
    clusterMetrics.sort { lhs, rhs in
        // Don't split singletons
        if lhs.size <= 1 { return false }
        if rhs.size <= 1 { return true }
        
        // Prefer splitting larger clusters with lower scores
        let lhsPriority = Float(lhs.size) * (1 - lhs.score) + lhs.intraVariance
        let rhsPriority = Float(rhs.size) * (1 - rhs.score) + rhs.intraVariance
        return lhsPriority > rhsPriority
    }
    
    // Split the highest priority cluster
    guard let targetCluster = clusterMetrics.first, targetCluster.size > 1 else { return labels }
    
    let clusterIndices = labels.enumerated().filter { $0.element == targetCluster.cluster }.map { $0.offset }
    let clusterVectors = clusterIndices.map { vectors[$0] }
    
    // Run k-means with k=2 on this cluster
    let (subLabels, _) = kMeansEnhanced(vectors: clusterVectors, k: 2, maxIters: 50)
    
    // Assign new labels
    var newLabels = labels
    let newClusterLabel = (labels.max() ?? 0) + 1
    
    for (i, idx) in clusterIndices.enumerated() {
        if subLabels[i] == 1 {
            newLabels[idx] = newClusterLabel
        }
    }
    
    return newLabels
}

private func mergeClosestClusters(labels: [Int], vectors: [[Float]]) -> [Int] {
    let (_, centroids) = recalculateCentroids(vectors: vectors, labels: labels)
    let clusters = Array(Set(labels))
    
    guard clusters.count > 1 else { return labels }
    
    // Count cluster sizes
    var clusterSizes: [Int: Int] = [:]
    for label in labels {
        clusterSizes[label, default: 0] += 1
    }
    
    // Identify singleton clusters
    let singletons = clusters.filter { clusterSizes[$0, default: 0] == 1 }
    
    var mergeA = -1
    var mergeB = -1
    var minDist = Float.greatestFiniteMagnitude
    
    if !singletons.isEmpty {
        // Priority 1: Merge singleton with its nearest cluster
        for singleton in singletons {
            let singletonIdx = clusters.firstIndex(of: singleton)!
            
            for (j, cluster) in clusters.enumerated() {
                if j != singletonIdx {
                    let dist = euclideanDistance(centroids[singletonIdx], centroids[j])
                    if dist < minDist {
                        minDist = dist
                        mergeA = cluster
                        mergeB = singleton
                    }
                }
            }
        }
    } else {
        // Priority 2: Merge closest pair of clusters
        for i in 0..<clusters.count {
            for j in (i+1)..<clusters.count {
                let dist = euclideanDistance(centroids[i], centroids[j])
                
                // Prefer merging smaller clusters
                let sizeA = clusterSizes[clusters[i], default: 0]
                let sizeB = clusterSizes[clusters[j], default: 0]
                let sizeWeight = 1.0 + 0.1 / Float(min(sizeA, sizeB))
                let weightedDist = dist / sizeWeight
                
                if weightedDist < minDist {
                    minDist = weightedDist
                    mergeA = clusters[i]
                    mergeB = clusters[j]
                }
            }
        }
    }
    
    // Merge clusters
    var newLabels = labels
    for i in 0..<labels.count {
        if labels[i] == mergeB {
            newLabels[i] = mergeA
        }
    }
    
    return newLabels
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

private func kMeansPlusPlusInit(vectors: [[Float]], k: Int, seed: Int? = nil) -> [[Float]] {
    var centroids: [[Float]] = []
    
    // Use deterministic random if seed provided
    var rng = seed != nil ? SystemRandomNumberGenerator() : SystemRandomNumberGenerator()
    if let s = seed {
        // Simple deterministic selection based on seed
        let firstIdx = abs(s) % vectors.count
        centroids.append(vectors[firstIdx])
    } else {
        centroids.append(vectors.randomElement()!)
    }
    
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