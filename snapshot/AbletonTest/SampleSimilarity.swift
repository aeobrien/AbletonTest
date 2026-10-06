import Foundation
import AVFoundation
import Accelerate

// MARK: - Public API

/// Call this with your audio file URLs to get 4 clusters x 5 round-robins.
public func groupSamplesIntoPseudoVelocityLayers(
    urls: [URL],
    clustersK: Int = 4,
    roundRobinsPerCluster: Int = 5,
    windowMs: Double = 256,
    alphaTimbreVsLoudness: Float = 0.8
) throws -> [[URL]] {
    // 1) Extract features
    let feats: [SampleFeatures] = try urls.map { try extractFeatures(from: $0, windowMs: windowMs) }
    // 2) Z-score normalise timbre features across dataset
    let normed = zScoreNormalize(features: feats)
    // 3) Run k-means on timbre vectors
    let (labels, _) = kMeans(vectors: normed.map { $0.timbreVector }, k: clustersK, maxIters: 100)
    // 4) Bundle by cluster and order clusters by median loudness
    var groups: [[(url: URL, feat: SampleFeatures)]] = Array(repeating: [], count: clustersK)
    for (i, lbl) in labels.enumerated() { groups[lbl].append((urls[i], feats[i])) }
    let ordered = groups.sorted { medianRMS($0.map { $0.feat.rms }) < medianRMS($1.map { $0.feat.rms }) }
    // 5) Within each cluster, pick round-robins by diversity (farthest-point)
    let results: [[URL]] = ordered.map { cluster in
        let vectors = cluster.map { zSafe($0.feat).timbreVector }
        let pickedIdx = pickDiverseIndices(vectors: vectors, count: roundRobinsPerCluster)
        return pickedIdx.map { cluster[$0].url }
    }
    return results
}

/// Automatically determine optimal grouping and return ALL samples
public func autoGroupSamplesIntoPseudoVelocityLayers(
    urls: [URL],
    windowMs: Double = 256,
    alphaTimbreVsLoudness: Float = 0.8
) throws -> [[URL]] {
    let sampleCount = urls.count
    
    // 1) Extract features
    let feats: [SampleFeatures] = try urls.map { try extractFeatures(from: $0, windowMs: windowMs) }
    
    // 2) Z-score normalise timbre features across dataset
    let normed = zScoreNormalize(features: feats)
    
    // 3) Determine optimal number of clusters
    let optimalClusters = determineOptimalClusters(sampleCount: sampleCount, features: normed)
    
    // 4) Run k-means on timbre vectors
    let (labels, _) = kMeans(vectors: normed.map { $0.timbreVector }, k: optimalClusters, maxIters: 100)
    
    // 5) Bundle by cluster and order clusters by median loudness
    var groups: [[(url: URL, feat: SampleFeatures)]] = Array(repeating: [], count: optimalClusters)
    for (i, lbl) in labels.enumerated() { groups[lbl].append((urls[i], feats[i])) }
    
    // Sort clusters by median RMS (quietest to loudest)
    let ordered = groups.sorted { medianRMS($0.map { $0.feat.rms }) < medianRMS($1.map { $0.feat.rms }) }
    
    // 6) Return ALL samples in each cluster, sorted by diversity
    let results: [[URL]] = ordered.map { cluster in
        let vectors = cluster.map { $0.feat.timbreVector }
        let sortedIndices = sortByDiversity(vectors: vectors)
        return sortedIndices.map { cluster[$0].url }
    }
    
    return results
}

/// Determine optimal number of clusters based on sample count and distribution
private func determineOptimalClusters(sampleCount: Int, features: [SampleFeatures]) -> Int {
    // Common instrument configurations:
    // 1 layer: All round-robins (good for 1-10 samples)
    // 2 layers: Split evenly (good for 10-20 samples)
    // 3 layers: Good for 15-30 samples
    // 4 layers: Good for 20-40 samples
    // 5+ layers: For larger sample sets
    
    if sampleCount <= 8 {
        return 1  // Single velocity layer with all as round-robins
    } else if sampleCount <= 16 {
        return 2  // Two velocity layers
    } else if sampleCount <= 24 {
        return 3  // Three velocity layers
    } else if sampleCount <= 32 {
        return 4  // Four velocity layers
    } else {
        // For larger sets, aim for roughly 5-8 samples per layer
        return min(8, max(4, sampleCount / 6))
    }
}

/// Sort samples within a cluster by diversity for optimal round-robin ordering
private func sortByDiversity(vectors: [[Float]]) -> [Int] {
    guard !vectors.isEmpty else { return [] }
    
    var indices = Array(0..<vectors.count)
    var sorted = [Int]()
    
    // Start with the first sample
    sorted.append(0)
    indices.remove(at: 0)
    
    // Greedily pick the most different sample each time
    while !indices.isEmpty {
        var bestIdx = 0
        var bestMinDist = -Float.greatestFiniteMagnitude
        
        for (i, idx) in indices.enumerated() {
            let minDist = sorted.map { cosineDistance(vectors[idx], vectors[$0]) }.min() ?? 0
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

// MARK: - Feature model

public struct SampleFeatures {
    // Loudness
    let rms: Float
    // Timbre descriptors (from attack window)
    let spectralCentroidHz: Float
    let spectralRolloffHz: Float  // 85%
    let spectralBandwidthHz: Float
    let spectralFlatness: Float
    let zeroCrossingRate: Float
    // Packed vector for clustering
    var timbreVector: [Float] {
        [spectralCentroidHz, spectralRolloffHz, spectralBandwidthHz, spectralFlatness, zeroCrossingRate]
    }
}

// MARK: - Extraction

public func extractFeatures(from url: URL, windowMs: Double) throws -> SampleFeatures {
    // Decode file
    let file = try AVAudioFile(forReading: url)
    
    // Check if file has any content
    guard file.length > 0 else {
        throw NSError(domain: "SampleSimilarity", code: -1, userInfo: [NSLocalizedDescriptionKey: "Audio file is empty"])
    }
    
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
    let converter = AVAudioConverter(from: file.processingFormat, to: format)!
    let frameCount = AVAudioFrameCount(file.length)
    let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)!
    try file.read(into: inputBuffer)

    let outFrames = AVAudioFrameCount(Double(frameCount) * (format.sampleRate / file.processingFormat.sampleRate))
    let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outFrames)!
    // Convert to 44.1k mono
    var error: NSError?
    converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
        outStatus.pointee = .haveData
        return inputBuffer
    }
    if let e = error { throw e }

    guard let ch = outputBuffer.floatChannelData?.pointee else { throw NSError(domain: "Extract", code: -1) }
    let n = Int(outputBuffer.frameLength)
    var x = Array(UnsafeBufferPointer(start: ch, count: n))

    // Simple DC offset removal
    var mean: Float = 0
    vDSP_meanv(x, 1, &mean, vDSP_Length(n))
    var negMean = -mean
    vDSP_vsadd(x, 1, &negMean, &x, 1, vDSP_Length(n))

    // Onset: first frame where short RMS crosses threshold
    let sr = Float(format.sampleRate)
    let hop = Int(256)
    let win = Int(1024)
    let onsetIdx = detectOnset(samples: x, win: win, hop: hop, thresholdRMS: 0.02) ?? 0

    // Attack window slice
    let attackLen = Int((windowMs / 1000.0) * Double(sr))
    let start = max(0, onsetIdx)
    let end = min(n, start + attackLen)
    let attack = Array(x[start..<end])
    let rms = rootMeanSquare(attack)

    // FFT-based descriptors on attack (Hann window)
    let fftFeats = spectralDescriptors(attack, sampleRate: sr)

    // ZCR on attack
    let zcr = zeroCrossingRate(attack)

    return SampleFeatures(
        rms: rms,
        spectralCentroidHz: fftFeats.centroidHz,
        spectralRolloffHz: fftFeats.rolloffHz,
        spectralBandwidthHz: fftFeats.bandwidthHz,
        spectralFlatness: fftFeats.flatness,
        zeroCrossingRate: zcr
    )
}

// MARK: - Onset (very simple)

private func detectOnset(samples: [Float], win: Int, hop: Int, thresholdRMS: Float) -> Int? {
    var i = 0
    while i + win <= samples.count {
        let seg = samples[i..<i+win]
        if rootMeanSquare(Array(seg)) > thresholdRMS { return i }
        i += hop
    }
    return nil
}

// MARK: - Descriptors

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
                        // Power spectrum (optional): vDSP_vsq(mag,...)
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

private func zeroCrossingRate(_ x: [Float]) -> Float {
    guard x.count > 1 else { return 0 }
    var count: Float = 0
    for i in 1..<x.count {
        if (x[i-1] >= 0 && x[i] < 0) || (x[i-1] < 0 && x[i] >= 0) { count += 1 }
    }
    return count / Float(x.count - 1)
}

private func rootMeanSquare(_ x: [Float]) -> Float {
    var val: Float = 0
    vDSP_measqv(x, 1, &val, vDSP_Length(x.count))
    return sqrt(val)
}

// MARK: - Normalisation

public func zScoreNormalize(features: [SampleFeatures]) -> [SampleFeatures] {
    let mat = features.map { $0.timbreVector }
    let cols = mat.first?.count ?? 0
    guard cols > 0 else { return features }
    // column means & stds
    var means = [Float](repeating: 0, count: cols)
    var stds  = [Float](repeating: 0, count: cols)
    for j in 0..<cols {
        let col = mat.map { $0[j] }
        vDSP_meanv(col, 1, &means[j], vDSP_Length(col.count))
        let m = means[j]
        var diff = [Float](repeating: 0, count: col.count)
        vDSP_vsadd(col, 1, [-m], &diff, 1, vDSP_Length(col.count))
        var sumsq: Float = 0
        vDSP_svesq(diff, 1, &sumsq, vDSP_Length(col.count))
        stds[j] = max(1e-6, sqrt(sumsq / Float(col.count)))
    }
    func normVec(_ v: [Float]) -> [Float] { zip(v.indices, v).map { (i, val) in (val - means[i]) / stds[i] } }
    return features.map {
        SampleFeatures(
            rms: $0.rms,
            spectralCentroidHz: $0.spectralCentroidHz,
            spectralRolloffHz: $0.spectralRolloffHz,
            spectralBandwidthHz: $0.spectralBandwidthHz,
            spectralFlatness: $0.spectralFlatness,
            zeroCrossingRate: $0.zeroCrossingRate
        ).replacingTimbre(normVec($0.timbreVector))
    }
}

private extension SampleFeatures {
    func replacingTimbre(_ v: [Float]) -> SampleFeatures {
        SampleFeatures(
            rms: self.rms,
            spectralCentroidHz: v[0],
            spectralRolloffHz: v[1],
            spectralBandwidthHz: v[2],
            spectralFlatness: v[3],
            zeroCrossingRate: v[4]
        )
    }
}

private func zSafe(_ f: SampleFeatures) -> SampleFeatures { f } // placeholder for extra guards

// MARK: - K-means (cosine distance)

private func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
    vDSP_dotpr(a, 1, a, 1, &na,  vDSP_Length(a.count))
    vDSP_dotpr(b, 1, b, 1, &nb,  vDSP_Length(a.count))
    let denom = (sqrt(na) * sqrt(nb))
    return 1 - (denom > 0 ? (dot / denom) : 0)
}

public func kMeans(vectors: [[Float]], k: Int, maxIters: Int) -> (labels: [Int], centroids: [[Float]]) {
    precondition(!vectors.isEmpty && k > 0)
    // Init with k random points
    var centroids = Array(vectors.shuffled().prefix(k))
    var labels = [Int](repeating: 0, count: vectors.count)

    for _ in 0..<maxIters {
        var changed = false
        // Assign
        for (i, v) in vectors.enumerated() {
            var best = 0
            var bestD = Float.greatestFiniteMagnitude
            for (cIdx, c) in centroids.enumerated() {
                let d = cosineDistance(v, c)
                if d < bestD { bestD = d; best = cIdx }
            }
            if labels[i] != best { labels[i] = best; changed = true }
        }
        if !changed { break }
        // Update
        for c in 0..<k {
            let members = vectors.enumerated().filter { labels[$0.offset] == c }.map { $0.element }
            if members.isEmpty { continue }
            let dim = members[0].count
            var mean = [Float](repeating: 0, count: dim)
            for v in members {
                vDSP_vadd(mean, 1, v, 1, &mean, 1, vDSP_Length(dim))
            }
            var inv = 1.0 / Float(members.count)
            vDSP_vsmul(mean, 1, &inv, &mean, 1, vDSP_Length(dim))
            centroids[c] = mean
        }
    }
    return (labels, centroids)
}

// MARK: - Round-robin selection (diversity)

private func pickDiverseIndices(vectors: [[Float]], count: Int) -> [Int] {
    guard !vectors.isEmpty else { return [] }
    var picked = [Int]()
    picked.append(0) // seed
    while picked.count < min(count, vectors.count) {
        var bestIdx = 0
        var bestMinD = -Float.greatestFiniteMagnitude
        for i in 0..<vectors.count where !picked.contains(i) {
            let dMin = picked.map { cosineDistance(vectors[i], vectors[$0]) }.min() ?? 0
            if dMin > bestMinD { bestMinD = dMin; bestIdx = i }
        }
        picked.append(bestIdx)
    }
    return picked
}

private func medianRMS(_ xs: [Float]) -> Float {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    let m = s.count / 2
    return s.count % 2 == 0 ? (s[m-1] + s[m]) * 0.5 : s[m]
}
