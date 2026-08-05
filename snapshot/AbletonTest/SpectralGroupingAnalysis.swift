import Foundation
import AVFoundation

// Import necessary types from ImprovedSampleSimilarity
// Note: These helper functions are reimplemented below to avoid cross-file dependencies

// =======================
// PREPROCESSING CONFIG
// =======================

struct PreprocConfig {
    let usePCAWhitening: Bool = false
    let pcaVariance: Float = 0.95
}

// =======================
// OBJECTIVE CONFIG
// =======================

struct ObjectiveConfig {
    let betaSize: Float = 0.15     // size imbalance penalty weight
    let lambdaK: Float = 0.15      // penalty for K drift from target
    let adjacencyWeight: Float = 0.2  // weight for adjacency mislabel penalty
}

// =======================
// REBALANCE CONFIG
// =======================

struct RebalanceConfig {
    let marginThreshold: Float = 1.2
    let sampleSilThreshold: Float = 0.10
    let maxMovesPerIter: Int = 3
    let maxIters: Int = 5
    let allowDrop: Float = 0.01
}

// =======================
// PREPROCESSING UTILITIES
// =======================

// Z-score normalization
func zscore(_ X: inout [[Float]]) {
    guard let d = X.first?.count, !X.isEmpty else { return }
    var mean = Array(repeating: Float(0), count: d)
    var varc = Array(repeating: Float(0), count: d)
    let n = Float(X.count)
    for v in X { for i in 0..<d { mean[i] += v[i] } }
    for i in 0..<d { mean[i] /= n }
    for v in X { for i in 0..<d { let t = v[i] - mean[i]; varc[i] += t * t } }
    for i in 0..<d { varc[i] = max(varc[i]/n, 1e-9) }
    for r in 0..<X.count { for i in 0..<d { X[r][i] = (X[r][i] - mean[i]) / sqrtf(varc[i]) } }
}

// =======================
// ENHANCED METRICS
// =======================

// Inline euclidean distance
@inline(__always) func euclid(_ a: [Float], _ b: [Float]) -> Float {
    var s: Float = 0
    let n = min(a.count, b.count)
    for i in 0..<n { let t = a[i] - b[i]; s += t * t }
    return sqrtf(s)
}

// Enhanced silhouette with per-sample and per-cluster breakdown
func silhouetteGlobalAndByCluster(X: [[Float]], y: [Int]) -> (global: Float, by: [Int:Float], perSample: [Float]) {
    let n = X.count
    guard n > 1 else { return (0, [:], Array(repeating: 0, count: n)) }
    
    // Precompute distance matrix
    var D = Array(repeating: Array(repeating: Float(0), count: n), count: n)
    for i in 0..<n {
        for j in i+1..<n {
            let d = euclid(X[i], X[j])
            D[i][j] = d
            D[j][i] = d
        }
    }
    
    let groups = Dictionary(grouping: Array(0..<n), by: { y[$0] })
    var sVals = [Float](repeating: 0, count: n)
    
    for i in 0..<n {
        let gi = y[i]
        let own = groups[gi] ?? []
        
        // Singleton clusters get silhouette = 0
        if own.count == 1 {
            sVals[i] = 0
            continue
        }
        
        let aCnt = own.count - 1
        let a = aCnt > 0 ? own.filter { $0 != i }.map { D[i][$0] }.reduce(0, +) / Float(aCnt) : 0
        
        var b = Float.greatestFiniteMagnitude
        for (g, mem) in groups where g != gi && !mem.isEmpty {
            let m = mem.map { D[i][$0] }.reduce(0, +) / Float(mem.count)
            if m < b { b = m }
        }
        
        let denom = max(a, b.isFinite ? b : 0)
        sVals[i] = denom > 0 ? ((b.isFinite ? b : 0) - a) / denom : 0
    }
    
    let global = sVals.reduce(0, +) / Float(n)
    var by: [Int:Float] = [:]
    for (g, mem) in groups {
        by[g] = mem.isEmpty ? 0 : mem.map { sVals[$0] }.reduce(0, +) / Float(mem.count)
    }
    
    return (global, by, sVals)
}

// Centroids with scatter
func centroidsGroups(X: [[Float]], y: [Int]) -> (cent: [Int:[Float]], groups: [Int:[Int]], scatter: [Int:Float]) {
    let idxByG = Dictionary(grouping: Array(0..<y.count), by: { y[$0] })
    var cent: [Int:[Float]] = [:]
    var scatter: [Int:Float] = [:]
    let d = X.first?.count ?? 0
    
    for (g, idxs) in idxByG {
        guard !idxs.isEmpty else { continue }
        var sum = Array(repeating: Float(0), count: d)
        for i in idxs {
            for k in 0..<d { sum[k] += X[i][k] }
        }
        let c = sum.map { $0 / Float(idxs.count) }
        cent[g] = c
        
        var s: Float = 0
        for i in idxs { s += euclid(X[i], c) }
        scatter[g] = s / Float(idxs.count)
    }
    
    return (cent, idxByG, scatter)
}

// Davies-Bouldin Index
func daviesBouldin(X: [[Float]], y: [Int]) -> Float {
    let (C, _, S) = centroidsGroups(X: X, y: y)
    let labels = Array(C.keys)
    guard labels.count > 1 else { return 0 }
    
    var sum: Float = 0
    for i in labels {
        var worst = Float.leastNonzeroMagnitude
        for j in labels where j != i {
            let m = euclid(C[i]!, C[j]!)
            if m > 0 {
                let r = (S[i]! + S[j]!) / m
                if r > worst { worst = r }
            }
        }
        sum += worst
    }
    
    return sum / Float(labels.count)
}

// Calinski-Harabasz Index
func calinskiHarabasz(X: [[Float]], y: [Int]) -> Float {
    let n = X.count
    guard n > 2 else { return 0 }
    let k = Set(y).count
    guard k > 1 && k < n else { return 0 }
    
    let d = X.first?.count ?? 0
    var mu = Array(repeating: Float(0), count: d)
    for v in X {
        for i in 0..<d { mu[i] += v[i] }
    }
    for i in 0..<d { mu[i] /= Float(n) }
    
    let (C, G, _) = centroidsGroups(X: X, y: y)
    var W: Float = 0
    var B: Float = 0
    
    for (g, idxs) in G {
        let c = C[g]!
        for i in idxs {
            for j in 0..<d {
                let t = X[i][j] - c[j]
                W += t * t
            }
        }
        var s: Float = 0
        for j in 0..<d {
            let t = c[j] - mu[j]
            s += t * t
        }
        B += Float(idxs.count) * s
    }
    
    return (B / Float(k - 1)) / (W / Float(n - k))
}

// Size inequality metrics
func sizeInequality(counts: [Int:Int]) -> (gini: Float, cv: Float) {
    let sizes = counts.values.map { Float($0) }
    guard !sizes.isEmpty else { return (0, 0) }
    
    let n = Float(sizes.count)
    let mean = sizes.reduce(0, +) / n
    let varSum = sizes.reduce(0) { $0 + powf($1 - mean, 2) }
    let cv = mean > 0 ? sqrtf(varSum / n) / mean : 0
    
    var g: Float = 0
    for a in sizes {
        for b in sizes {
            g += fabsf(a - b)
        }
    }
    let gini = (2 * g) / (n * n * (sizes.reduce(0, +) + 1e-12))
    
    return (gini, cv)
}

// Enhanced cluster sizes function
func enhancedClusterSizes(labels: [Int]) -> [Int:Int] {
    var c: [Int:Int] = [:]
    for g in labels { c[g, default: 0] += 1 }
    return c
}

// Count adjacent mislabels (for samples consecutive in file order)
func countAdjacentMislabels(labels: [Int]) -> (mislabelCount: Int, totalPairs: Int) {
    guard labels.count > 1 else { return (0, 0) }
    
    var mislabelCount = 0
    let totalPairs = labels.count - 1
    
    for i in 0..<(labels.count - 1) {
        if labels[i] != labels[i + 1] {
            mislabelCount += 1
        }
    }
    
    return (mislabelCount, totalPairs)
}

// Calculate adjacency error rate
func adjacencyErrorRate(labels: [Int]) -> Float {
    let (mislabels, total) = countAdjacentMislabels(labels: labels)
    return total > 0 ? Float(mislabels) / Float(total) : 0
}

// Boundary consistency scoring
func calculateBoundaryAmbiguity(
    manualGroups: [Int: [Int]],  // group -> sample indices
    features: [[Float]],
    centroids: [Int: [Float]]
) -> [Int: Float] {
    var ambiguity: [Int: Float] = [:]
    
    for (groupId, indices) in manualGroups {
        guard let groupCentroid = centroids[groupId] else { continue }
        
        // Calculate intra-group RMS distance
        var intraDistances: [Float] = []
        for idx in indices {
            if idx < features.count {
                intraDistances.append(euclid(features[idx], groupCentroid))
            }
        }
        let intraRMS = intraDistances.isEmpty ? 0 : 
            sqrtf(intraDistances.map { $0 * $0 }.reduce(0, +) / Float(intraDistances.count))
        
        // Find distance to nearest other manual centroid
        var nearestOtherDist = Float.greatestFiniteMagnitude
        for (otherId, otherCentroid) in centroids where otherId != groupId {
            let dist = euclid(groupCentroid, otherCentroid)
            if dist < nearestOtherDist {
                nearestOtherDist = dist
            }
        }
        
        // Calculate ratio
        let ratio = nearestOtherDist.isFinite ? intraRMS / max(nearestOtherDist, 1e-6) : 0
        ambiguity[groupId] = ratio
    }
    
    return ambiguity
}

// =======================
// SIZE & ADJACENCY UTILS
// =======================

// Return cluster sizes ordered by group id
func clusterSizes(from labels: [Int]) -> [Int] {
    var counts: [Int:Int] = [:]
    for g in labels { counts[g, default: 0] += 1 }
    return counts.keys.sorted().map { counts[$0]! }
}

// Entropy of size distribution (0..1 normalised). Higher == more balanced.
func sizeEntropy(_ counts: [Int]) -> Float {
    let n = Float(counts.reduce(0,+)); guard n > 0 else { return 0 }
    var h: Float = 0
    for c in counts where c > 0 { let p = Float(c)/n; h -= p * logf(p) }
    return h / max(logf(Float(max(counts.count,1))), 1e-6)
}

// Soft penalty for deviation from uniform, with tolerance band (e.g., 25%)
func sizeDeviationPenalty(_ counts: [Int], tolerance: Float) -> Float {
    let n = Float(counts.reduce(0,+)); let k = Float(max(counts.count,1))
    let target = n / k
    var pen: Float = 0
    for c in counts {
        let cf = Float(c)
        let upper = target * (1 + tolerance)
        let lower = target * (1 - tolerance)
        let over  = max(0, cf - upper)
        let under = max(0, lower - cf)
        pen += (over*over + under*under) / max(target*target, 1e-6)
    }
    return pen / k
}

// Order clusters along the dimension of max variance across centroids
func clusterOrderBy1D(_ centroids: [[Float]]) -> [Int] {
    guard let d = centroids.first?.count, d > 0 else { return Array(centroids.indices) }
    var bestDim = 0; var bestVar: Float = -1
    for j in 0..<d {
        let vals = centroids.map { $0[j] }
        let mean = vals.reduce(0,+) / Float(vals.count)
        let v = vals.reduce(0) { $0 + ( $1 - mean ) * ( $1 - mean ) } / Float(vals.count)
        if v > bestVar { bestVar = v; bestDim = j }
    }
    return centroids.indices.sorted { centroids[$0][bestDim] < centroids[$1][bestDim] }
}

// Penalise large size jumps between adjacent clusters (neighbours in 1-D order)
func adjacencyPenalty(counts: [Int], order: [Int]) -> Float {
    guard order.count > 1 else { return 0 }
    var pen: Float = 0
    for i in 0..<(order.count - 1) {
        let a = counts[order[i]], b = counts[order[i+1]]
        pen += Float(abs(a - b))
    }
    let n = Float(counts.reduce(0,+))
    return pen / max(n, 1e-6)
}

// ============
// SCORE BLEND
// ============

// Legacy Quality struct kept for compatibility
struct Quality { let sil: Float; let dbi: Float?; let ch: Float? }

// Enhanced ClusterQuality for new objective
struct EnhancedClusterQuality { 
    let sil: Float
    let dbi: Float?
    let ch: Float?
}

// Unified objective score function
func overallQualityScore(
    q: EnhancedClusterQuality,
    counts: [Int:Int],
    n: Int,
    k: Int,
    kTarget: Int,
    labels: [Int]? = nil,
    cfg: ObjectiveConfig = ObjectiveConfig()
) -> Float {
    var s = q.sil
    if let db = q.dbi, db.isFinite {
        s += max(0, 1.0 - min(db, 2.0)) * 0.2
    }
    if let chv = q.ch, chv.isFinite {
        s += min(chv / 1000.0, 0.2)
    }
    let (_, cv) = sizeInequality(counts: counts)
    s += -cfg.betaSize * min(cv, 1.0)
    s += -cfg.lambdaK * powf(Float(k - kTarget), 2)
    
    // Add adjacency penalty if labels provided
    if let labels = labels {
        let adjErr = adjacencyErrorRate(labels: labels)
        s -= cfg.adjacencyWeight * adjErr
    }
    
    return s
}

// Legacy function updated to use new metrics but keeping same signature
func modelSelScore(
    quality q: Quality,
    counts: [Int],
    centroids: [[Float]],
    targetK: Int?,
    lambdaK: Float = 0.12,
    wEntropy: Float = 0.15,
    wDev: Float = 0.15,
    wAdj: Float = 0.10,
    sizeTolerance: Float = 0.25
) -> Float {
    var s = q.sil
    if let db = q.dbi { s += max(0, 1 - min(db, 2)) * 0.2 }
    if let ch = q.ch  { s += min(ch / 1000, 0.2) }
    // Size equity
    s += wEntropy * sizeEntropy(counts)
    s -= wDev * sizeDeviationPenalty(counts, tolerance: sizeTolerance)
    // Local adjacency
    let order = clusterOrderBy1D(centroids)
    s -= wAdj * adjacencyPenalty(counts: counts, order: order)
    if let t = targetK { s += -lambdaK * powf(Float(counts.count - t), 2) }
    return s
}

// =======================
// MARGIN & AMBIGUITY
// =======================

// Euclidean distance
func dist(_ a: [Float], _ b: [Float]) -> Float {
    var s: Float = 0; let n = min(a.count, b.count)
    for i in 0..<n { let d = a[i]-b[i]; s += d*d }
    return sqrtf(s)
}

struct MarginInfo { let nearest: Int; let second: Int; let margin: Float } // gamma = d2/d1

func computeMargins(X: [[Float]], centroids: [[Float]]) -> [MarginInfo] {
    var out: [MarginInfo] = []
    for v in X {
        var best = (idx: -1, d: Float.greatestFiniteMagnitude)
        var second = (idx: -1, d: Float.greatestFiniteMagnitude)
        for (j,c) in centroids.enumerated() {
            let d = dist(v, c)
            if d < best.d { second = best; best = (j,d) }
            else if d < second.d { second = (j,d) }
        }
        let gamma = (second.d.isFinite && best.d > 0) ? (second.d / best.d) : 999
        out.append(MarginInfo(nearest: best.idx, second: second.idx, margin: gamma))
    }
    return out
}

// =======================
// REBALANCING UTILITIES
// =======================

// Build centroids from labels (use the same normalised/whitened space used for clustering)
func centroids(for labels: [Int], X: [[Float]]) -> [[Float]] {
    let kset = Array(Set(labels)).sorted()
    guard let d = X.first?.count else { return [] }
    var sums = Array(repeating: Array(repeating: Float(0), count: d), count: kset.count)
    var cnts = Array(repeating: 0, count: kset.count)
    for (i,g) in labels.enumerated() {
        if let gi = kset.firstIndex(of: g) {
            for j in 0..<d { sums[gi][j] += X[i][j] }
            cnts[gi] += 1
        }
    }
    for gi in 0..<kset.count {
        let c = max(cnts[gi], 1)
        for j in 0..<d { sums[gi][j] /= Float(c) }
    }
    return sums
}

// Quality provider closure stub you'll wire to your silhouette/DBI/CH
// e.g., qualityProvider(labels) -> Quality(sil: globalSil, dbi: dbi, ch: ch)

func rebalanceBySize(
    labels: inout [Int],
    X: [[Float]],
    qualityProvider: ([Int]) -> Quality,
    targetK: Int? = nil,
    marginThreshold: Float = 1.25,
    tolerance: Float = 0.25,
    maxMovesPerPair: Int = 2,
    epsilon: Float = 0.002
) {
    var cents = centroids(for: labels, X: X)
    var counts = clusterSizes(from: labels)
    let baseQual = qualityProvider(labels)
    var baseScore = modelSelScore(quality: baseQual, counts: counts, centroids: cents, targetK: targetK)
    // Neighbour order
    let order = clusterOrderBy1D(cents)
    var neighbourPairs: Set<[Int]> = []
    for i in 0..<(order.count - 1) { 
        let pair = [order[i], order[i+1]].sorted()
        neighbourPairs.insert(pair) 
    }

    let margins = computeMargins(X: X, centroids: cents)
    // Donors/receivers by tolerance around the uniform target
    let n = Float(labels.count), k = Float(max(counts.count,1))
    let target = n / k
    var donors: Set<Int> = [], receivers: Set<Int> = []
    for (g, c) in counts.enumerated() {
        if Float(c) > target * (1 + tolerance) { donors.insert(g) }
        if Float(c) < target * (1 - tolerance) { receivers.insert(g) }
    }
    guard !donors.isEmpty && !receivers.isEmpty else { return }

    // Try moving low-margin items from donors to neighbouring receivers
    for pair in neighbourPairs {
        let a = pair[0], b = pair[1]
        if (donors.contains(a) && receivers.contains(b)) || (donors.contains(b) && receivers.contains(a)) {
            let donor = donors.contains(a) ? a : b
            let receiver = donors.contains(a) ? b : a
            
            var moved = 0
            for i in 0..<labels.count where labels[i] == donor {
                let mi = margins[i]
                if (mi.second == receiver && mi.margin < marginThreshold) || (mi.nearest == receiver) {
                    let old = labels[i]
                    labels[i] = receiver
                    // Re-score
                    cents = centroids(for: labels, X: X)
                    counts = clusterSizes(from: labels)
                    let qual = qualityProvider(labels)
                    let newScore = modelSelScore(quality: qual, counts: counts, centroids: cents, targetK: targetK)
                    if newScore + epsilon >= baseScore {
                        baseScore = newScore
                        moved += 1
                        if moved >= maxMovesPerPair { break }
                    } else {
                        labels[i] = old // revert
                    }
                }
            }
        }
    }
}

// =======================
// CAPACITATED ASSIGNMENT
// =======================

struct CapConfig {
    let tolerance: Float   // e.g., 0.25 (±25%)
    let maxMoves: Int      // total ambiguous moves cap, e.g., 6
    let marginThreshold: Float // e.g., 1.25
    let neighbourBonus: Float  // subtract from cost if neighbour, e.g., 0.05 * avgDist
}

func targetSizes(current counts: [Int]) -> [Int] {
    let n = counts.reduce(0,+)
    let k = max(counts.count, 1)
    let base = n / k
    var targets = Array(repeating: base, count: k)
    // Distribute remainder to clusters with lowest sizes
    var rem = n - targets.reduce(0,+)
    var idx = 0
    while rem > 0 { targets[idx % k] += 1; idx += 1; rem -= 1 }
    return targets
}

struct Slot { let clusterIndex: Int } // one Slot per available capacity unit

func buildSlots(counts: [Int], tol: Float) -> [Slot] {
    let targets = targetSizes(current: counts)
    var slots: [Slot] = []
    for (g, c) in counts.enumerated() {
        let tgt = targets[g]
        // Only create slots if current size > target*(1 - tol) ? No.
        // We create slots = max(0, tgtHigh - c), where tgtHigh = ceil(tgt*(1+tol))
        let upper = Int(ceil(Float(tgt) * (1 + tol)))
        let deficit = max(0, upper - c)
        for _ in 0..<deficit { slots.append(Slot(clusterIndex: g)) }
    }
    return slots
}

// Minimal Hungarian for small problems. Costs must be non-negative.
struct Assignment { let rowToCol: [Int] }

func hungarian(_ cost: [[Float]]) -> Assignment {
    let n = max(cost.count, cost.first?.count ?? 0)
    // Pad to square
    var C = Array(repeating: Array(repeating: Float(0), count: n), count: n)
    for i in 0..<n { for j in 0..<n { C[i][j] = (i < cost.count && j < cost[i].count) ? cost[i][j] : 1e6 } }

    // Row reduction
    for i in 0..<n {
        let m = C[i].min() ?? 0
        for j in 0..<n { C[i][j] -= m }
    }
    // Column reduction
    for j in 0..<n {
        var m = Float.greatestFiniteMagnitude
        for i in 0..<n { m = min(m, C[i][j]) }
        for i in 0..<n { C[i][j] -= m }
    }

    var rowCover = Array(repeating: false, count: n)
    var colCover = Array(repeating: false, count: n)
    var star = Array(repeating: Array(repeating: false, count: n), count: n)
    var prime = Array(repeating: Array(repeating: false, count: n), count: n)

    // Star zeros greedily
    for i in 0..<n {
        for j in 0..<n where C[i][j] == 0 && !rowCover[i] && !colCover[j] {
            star[i][j] = true
            rowCover[i] = true; colCover[j] = true
        }
    }
    rowCover = Array(repeating: false, count: n)
    colCover = Array(repeating: false, count: n)
    for i in 0..<n { for j in 0..<n where star[i][j] { colCover[j] = true } }

    func findZero() -> (Int,Int)? {
        for i in 0..<n where !rowCover[i] {
            for j in 0..<n where !colCover[j] {
                if C[i][j] == 0 { return (i,j) }
            }
        }
        return nil
    }

    func findStarInRow(_ r: Int) -> Int? { for j in 0..<n { if star[r][j] { return j } } ; return nil }
    func findStarInCol(_ c: Int) -> Int? { for i in 0..<n { if star[i][c] { return i } } ; return nil }
    func findPrimeInRow(_ r: Int) -> Int? { for j in 0..<n { if prime[r][j] { return j } } ; return nil }

    while true {
        // Step: if all columns covered, we have an assignment
        var coveredCols = 0
        for j in 0..<n { if colCover[j] { coveredCols += 1 } }
        if coveredCols == n { break }

        // Find uncovered zero
        guard let (r,c) = findZero() else {
            // Adjust matrix
            var minUncovered = Float.greatestFiniteMagnitude
            for i in 0..<n where !rowCover[i] {
                for j in 0..<n where !colCover[j] { minUncovered = min(minUncovered, C[i][j]) }
            }
            for i in 0..<n where rowCover[i] { for j in 0..<n { C[i][j] += minUncovered } }
            for j in 0..<n where !colCover[j] { for i in 0..<n { C[i][j] -= minUncovered } }
            continue
        }
        prime[r][c] = true
        if let j = findStarInRow(r) {
            // Cover this row and uncover the starred column
            rowCover[r] = true
            colCover[j] = false
        } else {
            // Augmenting path
            var path: [(Int,Int)] = [(r,c)]
            var done = false
            while !done {
                if let iStar = findStarInCol(path.last!.1) {
                    path.append((iStar, path.last!.1))
                    if let jPrime = findPrimeInRow(iStar) {
                        path.append((iStar, jPrime))
                    }
                } else { done = true }
            }
            // Flip stars/primes on path
            for (ri,ci) in path {
                if star[ri][ci] { star[ri][ci] = false } else { star[ri][ci] = true }
            }
            // Clear covers and primes
            rowCover = Array(repeating: false, count: n)
            colCover = Array(repeating: false, count: n)
            prime = Array(repeating: Array(repeating: false, count: n), count: n)
            // Cover columns with stars
            for i in 0..<n { for j in 0..<n where star[i][j] { colCover[j] = true } }
        }
    }

    var rowToCol = Array(repeating: -1, count: n)
    for i in 0..<n { for j in 0..<n where star[i][j] { rowToCol[i] = j } }
    return Assignment(rowToCol: rowToCol)
}

// Build cost = distance to slot's centroid (minus small neighbour bonus).
// Only ambiguous items (margin < threshold) participate.
func capacitatedReassign(
    labels: inout [Int],
    X: [[Float]],
    qualityProvider: ([Int]) -> Quality,
    marginThreshold: Float = 1.25,
    tol: Float = 0.25,
    neighbourBonus: Float = 0.05,     // fraction of mean distance to subtract if neighbour
    maxTotalMoves: Int = 6
) {
    let cents = centroids(for: labels, X: X)
    let counts = clusterSizes(from: labels)
    let order = clusterOrderBy1D(cents)
    var neighbourPairs: Set<[Int]> = []
    for i in 0..<(order.count - 1) { 
        let pair = [order[i], order[i+1]].sorted()
        neighbourPairs.insert(pair) 
    }

    let margins = computeMargins(X: X, centroids: cents)
    var ambIdxs: [Int] = []
    for i in 0..<labels.count { if margins[i].margin < marginThreshold { ambIdxs.append(i) } }
    guard !ambIdxs.isEmpty else { return }

    // Build slots from cluster deficits relative to tolerant targets
    let slots = buildSlots(counts: counts, tol: tol)
    guard !slots.isEmpty else { return }

    // Mean inter-centroid distance (for scaling the neighbour bonus)
    var meanC: Float = 0; var cc = 0
    for i in 0..<cents.count { for j in i+1..<cents.count { meanC += dist(cents[i], cents[j]); cc += 1 } }
    meanC = cc > 0 ? meanC / Float(cc) : 1

    // Cost matrix (ambiguous × slots)
    var cost: [[Float]] = Array(repeating: Array(repeating: 0, count: slots.count), count: ambIdxs.count)
    for (ri, idx) in ambIdxs.enumerated() {
        for (cj, slot) in slots.enumerated() {
            var c = dist(X[idx], cents[slot.clusterIndex])
            // adjacency bonus: if moving to neighbour, discount a bit
            let from = labels[idx], to = slot.clusterIndex
            let neighbourKey = [min(from,to), max(from,to)]
            if neighbourPairs.contains(neighbourKey) {
                c = max(0, c - neighbourBonus * meanC)
            }
            cost[ri][cj] = c
        }
    }

    // Solve assignment
    let assign = hungarian(cost)
    var moves = [(sample: Int, to: Int, c: Float)]()
    for (ri, cj) in assign.rowToCol.enumerated() {
        if ri < ambIdxs.count && cj < slots.count {
            let i = ambIdxs[ri]
            let targetCluster = slots[cj].clusterIndex
            if targetCluster != labels[i] {
                moves.append((sample: i, to: targetCluster, c: cost[ri][cj]))
            }
        }
    }

    // Apply moves greedily while monitoring overall score
    var applied = 0
    var bestLabels = labels
    var bestScore = modelSelScore(
        quality: qualityProvider(labels),
        counts: clusterSizes(from: labels),
        centroids: cents,
        targetK: nil
    )

    for m in moves {
        let old = labels[m.sample]
        labels[m.sample] = m.to
        let cents2 = centroids(for: labels, X: X)
        let score2 = modelSelScore(
            quality: qualityProvider(labels),
            counts: clusterSizes(from: labels),
            centroids: cents2,
            targetK: nil
        )
        if score2 >= bestScore { bestScore = score2; bestLabels = labels; applied += 1 }
        else { labels[m.sample] = old } // revert
        if applied >= maxTotalMoves { break }
    }
    labels = bestLabels
}

// =======================
// CLUSTERING STATE & CALIBRATION
// =======================

struct ClusteringStateEnhanced {
    var X: [[Float]]
    var labels: [Int]
    var centroids: [Int:[Float]]
    var silGlobal: Float
    var silByCluster: [Int:Float]
    var dbi: Float?
    var ch: Float?
}

func recomputeState(_ st: ClusteringStateEnhanced) -> ClusteringStateEnhanced {
    let y = st.labels
    let (sil, by, _) = silhouetteGlobalAndByCluster(X: st.X, y: y)
    let db = daviesBouldin(X: st.X, y: y)
    let chv = calinskiHarabasz(X: st.X, y: y)
    let (cent, _, _) = centroidsGroups(X: st.X, y: y)
    return ClusteringStateEnhanced(
        X: st.X, 
        labels: y, 
        centroids: cent, 
        silGlobal: sil, 
        silByCluster: by, 
        dbi: db, 
        ch: chv
    )
}

// Local bisecting k-means for splitting
func localBisectingKMeans(X: [[Float]], idxs: [Int], maxIter: Int = 20) -> [Bool] {
    guard idxs.count >= 2 else { return Array(repeating: false, count: idxs.count) }
    
    // Initialize centers as two furthest points
    var bestA = 0, bestB = 1, bestD: Float = -1
    for i in 0..<idxs.count {
        for j in i+1..<idxs.count {
            let d = euclid(X[idxs[i]], X[idxs[j]])
            if d > bestD { bestD = d; bestA = i; bestB = j }
        }
    }
    var c0 = X[idxs[bestA]], c1 = X[idxs[bestB]]
    var assign = [Bool](repeating: false, count: idxs.count)
    
    for _ in 0..<maxIter {
        var changed = false
        // Assignment step
        for (t, i) in idxs.enumerated() {
            let d0 = euclid(X[i], c0), d1 = euclid(X[i], c1)
            let a = d1 < d0
            if a != assign[t] { assign[t] = a; changed = true }
        }
        if !changed { break }
        
        // Update step
        func mean(_ pick: Bool) -> [Float] {
            let sel = zip(assign, idxs).filter { $0.0 == pick }.map { X[$0.1] }
            guard let d = X.first?.count, !sel.isEmpty else { return pick ? c1 : c0 }
            var sum = Array(repeating: Float(0), count: d)
            for v in sel { for k in 0..<d { sum[k] += v[k] } }
            return sum.map { $0 / Float(sel.count) }
        }
        c0 = mean(false)
        c1 = mean(true)
    }
    return assign
}

// Split worst cluster
func splitCluster(_ st: ClusteringStateEnhanced, clusterId: Int) -> ClusteringStateEnhanced {
    var st = st
    let idxs = st.labels.enumerated().filter { $0.element == clusterId }.map(\.offset)
    guard idxs.count >= 4 else { return st } // Avoid splitting tiny clusters
    
    let assign = localBisectingKMeans(X: st.X, idxs: idxs)
    let newId = (st.centroids.keys.max() ?? clusterId) + 1
    for (k, i) in idxs.enumerated() {
        st.labels[i] = assign[k] ? newId : clusterId
    }
    return recomputeState(st)
}

// Merge best pair
func mergeBestPair(_ st: ClusteringStateEnhanced, kTarget: Int, objCfg: ObjectiveConfig) -> ClusteringStateEnhanced {
    var best: (Float, ClusteringStateEnhanced)? = nil
    let labs = Array(Set(st.labels))
    
    // Consider a few closest pairs
    for i in 0..<labs.count {
        for j in i+1..<labs.count {
            var t = st
            let a = labs[i], b = labs[j]
            for p in 0..<t.labels.count {
                if t.labels[p] == b { t.labels[p] = a }
            }
            t = recomputeState(t)
            
            let counts = enhancedClusterSizes(labels: t.labels)
            let q = EnhancedClusterQuality(sil: t.silGlobal, dbi: t.dbi, ch: t.ch)
            let s = overallQualityScore(
                q: q, 
                counts: counts, 
                n: t.labels.count, 
                k: counts.count, 
                kTarget: kTarget, 
                cfg: objCfg
            )
            
            if best == nil || s > best!.0 {
                best = (s, t)
            }
        }
    }
    return best?.1 ?? st
}

// Main calibration function
func calibrateToK(_ st0: ClusteringStateEnhanced, kTarget: Int, objCfg: ObjectiveConfig = ObjectiveConfig()) -> ClusteringStateEnhanced {
    var st = st0
    
    // Improved singleton handling - treat as provisional
    var counts = enhancedClusterSizes(labels: st.labels)
    let singletonIds = counts.filter { $0.value == 1 }.map(\.key)
    
    func score(_ state: ClusteringStateEnhanced) -> Float {
        let c = enhancedClusterSizes(labels: state.labels)
        let q = EnhancedClusterQuality(sil: state.silGlobal, dbi: state.dbi, ch: state.ch)
        return overallQualityScore(q: q, counts: c, n: state.labels.count, k: c.count, kTarget: kTarget, cfg: objCfg)
    }
    
    let baselineScore = score(st)
    
    for gid in singletonIds {
        let idx = st.labels.firstIndex(of: gid)!
        
        // Find nearest non-singleton centroid
        let nearest = st.centroids
            .filter { $0.key != gid && counts[$0.key, default: 0] > 1 }
            .min(by: { euclid(st.X[idx], $0.value) < euclid(st.X[idx], $1.value) })?.key
        
        guard let target = nearest else { continue }
        
        var trial = st
        trial.labels[idx] = target
        trial = recomputeState(trial)
        
        // Accept move only if overallQualityScore >= baseline
        if score(trial) >= baselineScore {
            st = trial
            counts = enhancedClusterSizes(labels: st.labels)
            
            // Update silhouette to reflect singleton was removed
            if var silByCluster = st.silByCluster as? [Int: Float?] {
                silByCluster[gid] = nil
                st.silByCluster = silByCluster.compactMapValues { $0 }
            }
        }
    }
    
    // Split/merge until K matches
    while Set(st.labels).count != kTarget {
        counts = enhancedClusterSizes(labels: st.labels)
        
        if counts.count < kTarget {
            // Split worst cluster by silhouette
            let worst = st.silByCluster.min { $0.value < $1.value }?.key
            if let w = worst {
                st = splitCluster(st, clusterId: w)
            } else {
                break
            }
        } else {
            st = mergeBestPair(st, kTarget: kTarget, objCfg: objCfg)
        }
    }
    
    return st
}

// Enhanced rebalancing with margins and sample silhouettes
func rebalanceSizes(_ st0: ClusteringStateEnhanced, kTarget: Int,
                    margins: [Float]?, sampleSil: [Float],
                    objCfg: ObjectiveConfig = ObjectiveConfig(),
                    cfg: RebalanceConfig = RebalanceConfig()) -> ClusteringStateEnhanced {
    var st = st0
    let N = st.labels.count
    
    func score(_ t: ClusteringStateEnhanced) -> Float {
        let counts = enhancedClusterSizes(labels: t.labels)
        let q = EnhancedClusterQuality(sil: t.silGlobal, dbi: t.dbi, ch: t.ch)
        return overallQualityScore(q: q, counts: counts, n: N, k: counts.count, kTarget: kTarget, cfg: objCfg)
    }
    
    var iter = 0
    while iter < cfg.maxIters {
        iter += 1
        let counts = enhancedClusterSizes(labels: st.labels)
        let K = counts.count
        let target = Int(round(Float(N) / Float(K)))
        
        let oversized = counts.filter { $0.value >= target + 2 }.map(\.key)
        let undersized = counts.filter { $0.value <= target - 2 }.map(\.key)
        
        if oversized.isEmpty || undersized.isEmpty { break }
        
        // Calculate CV before moves
        let (_, cvBefore) = sizeInequality(counts: counts)
        
        var moves: [(gain: Float, idx: Int, to: Int, cvReduction: Float)] = []
        
        for (idx, g) in st.labels.enumerated() where oversized.contains(g) {
            let ms = margins?[idx] ?? Float.infinity
            let si = sampleSil[idx]
            
            if !(ms < cfg.marginThreshold || si < cfg.sampleSilThreshold) { continue }
            
            // Find nearest undersized centroid
            var bestTo = -1
            var bestD = Float.infinity
            for u in undersized {
                if let c = st.centroids[u] {
                    let d = euclid(st.X[idx], c)
                    if d < bestD { bestD = d; bestTo = u }
                }
            }
            
            if bestTo < 0 { continue }
            
            var t = st
            t.labels[idx] = bestTo
            t = recomputeState(t)
            
            // Calculate scores and CV reduction
            let g0 = score(st), g1 = score(t)
            let countsAfter = enhancedClusterSizes(labels: t.labels)
            let (_, cvAfter) = sizeInequality(counts: countsAfter)
            let cvReduction = cvBefore - cvAfter
            
            moves.append((g1 - g0, idx, bestTo, cvReduction))
        }
        
        // Select moves: accept if gain >= -allowDrop OR CV reduction >= 0.10
        let selected = moves.sorted { $0.gain > $1.gain }
            .prefix(cfg.maxMovesPerIter)
            .filter { $0.gain >= -cfg.allowDrop || $0.cvReduction >= 0.10 }
        
        if selected.isEmpty { break }
        
        for mv in selected {
            st.labels[mv.idx] = mv.to
        }
        st = recomputeState(st)
    }
    
    return st
}

// =======================
// HELPER FUNCTIONS
// =======================

// Simple feature normalization
func sg_normalizeEnhancedFeatures(_ features: [EnhancedSampleFeatures]) -> [EnhancedSampleFeatures] {
    // For now, just return as-is (normalization happens in PCA whitening)
    return features
}

// PCA whitening
func sg_pcaWhitening(vectors: [[Float]]) -> [[Float]] {
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
    
    // Apply whitening transform
    var whitened = centered
    for i in 0..<n {
        for j in 0..<d {
            let std = sqrt(max(variances[j], 1e-6))
            whitened[i][j] /= std
        }
    }
    
    return whitened
}

// Median value
func sg_medianValue(_ values: [Float]) -> Float {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    return sorted.count % 2 == 0 ? (sorted[mid-1] + sorted[mid]) * 0.5 : sorted[mid]
}

// Sort by diversity
func sg_sortByDiversityEnhanced(vectors: [[Float]]) -> [Int] {
    guard !vectors.isEmpty else { return [] }
    
    var indices = Array(0..<vectors.count)
    var sorted = [Int]()
    
    // Start with the sample closest to the centroid
    let centroid = sg_calculateCentroid(vectors)
    let startIdx = indices.min { dist(vectors[$0], centroid) < dist(vectors[$1], centroid) }!
    
    sorted.append(startIdx)
    indices.remove(at: indices.firstIndex(of: startIdx)!)
    
    // Greedily pick the most different sample each time
    while !indices.isEmpty {
        var bestIdx = 0
        var bestMinDist = -Float.greatestFiniteMagnitude
        
        for (i, idx) in indices.enumerated() {
            let minDist = sorted.map { dist(vectors[idx], vectors[$0]) }.min() ?? 0
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

func sg_calculateCentroid(_ vectors: [[Float]]) -> [Float] {
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

// K-means++ enhanced
func sg_kMeansEnhanced(vectors: [[Float]], k: Int, maxIters: Int, seed: Int? = nil) -> (labels: [Int], centroids: [[Float]]) {
    // Use k-means++ initialization
    var centroids = sg_kMeansPlusPlusInit(vectors: vectors, k: k, seed: seed)
    var labels = [Int](repeating: 0, count: vectors.count)
    
    for _ in 0..<maxIters {
        var changed = false
        
        // Assignment step
        for (i, v) in vectors.enumerated() {
            var bestCluster = 0
            var bestDist = Float.greatestFiniteMagnitude
            
            for (j, c) in centroids.enumerated() {
                let d = dist(v, c)
                if d < bestDist {
                    bestDist = d
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
                centroids[c] = sg_calculateCentroid(members)
            }
        }
    }
    
    return (labels, centroids)
}

func sg_kMeansPlusPlusInit(vectors: [[Float]], k: Int, seed: Int? = nil) -> [[Float]] {
    var centroids: [[Float]] = []
    
    // Use deterministic random if seed provided
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
            let minDist = centroids.map { dist(vector, $0) }.min() ?? 0
            distances.append(minDist * minDist)
        }
        
        // Choose next centroid with probability proportional to squared distance
        let totalDist = distances.reduce(0, +)
        var randomValue = Float.random(in: 0..<totalDist)
        
        for (i, d) in distances.enumerated() {
            randomValue -= d
            if randomValue <= 0 {
                centroids.append(vectors[i])
                break
            }
        }
    }
    
    return centroids
}

// Silhouette score (treating singletons as 0)
func sg_calculateSilhouetteScore(vectors: [[Float]], labels: [Int]) -> Float {
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
        let a = sameCluster.isEmpty ? 0 : sameCluster.map { dist(vector, $0.element) }.reduce(0, +) / Float(sameCluster.count)
        
        // Calculate b(i) - minimum average distance to points in other clusters
        var b = Float.greatestFiniteMagnitude
        let otherClusters = Set(labels).filter { $0 != cluster }
        
        for otherCluster in otherClusters {
            let otherPoints = vectors.enumerated().filter { labels[$0.offset] == otherCluster }
            if !otherPoints.isEmpty {
                let avgDist = otherPoints.map { dist(vector, $0.element) }.reduce(0, +) / Float(otherPoints.count)
                b = min(b, avgDist)
            }
        }
        
        // Silhouette coefficient for this point
        let s = (b - a) / max(a, b)
        totalScore += s
    }
    
    return totalScore / Float(vectors.count)
}

// Davies-Bouldin Index
func sg_calculateDaviesBouldinIndex(vectors: [[Float]], labels: [Int], centroids: [[Float]]) -> Float? {
    let k = centroids.count
    guard k > 1 else { return nil }
    
    // Calculate average distance within each cluster
    var avgDistances = [Float](repeating: 0, count: k)
    var clusterCounts = [Int](repeating: 0, count: k)
    
    for (i, vector) in vectors.enumerated() {
        let cluster = labels[i]
        avgDistances[cluster] += dist(vector, centroids[cluster])
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
            let centroidDist = dist(centroids[i], centroids[j])
            if centroidDist > 0 {
                let ratio = (avgDistances[i] + avgDistances[j]) / centroidDist
                maxRatio = max(maxRatio, ratio)
            }
        }
        
        dbIndex += maxRatio
    }
    
    return dbIndex / Float(k)
}

// Calinski-Harabasz Index
func sg_calculateCalinskiHarabaszIndex(vectors: [[Float]], labels: [Int], centroids: [[Float]]) -> Float? {
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
        let d = dist(centroid, overallCentroid)
        betweenScatter += Float(clusterCounts[i]) * d * d
    }
    
    // Within-cluster scatter
    var withinScatter: Float = 0
    for (i, vector) in vectors.enumerated() {
        let cluster = labels[i]
        let d = dist(vector, centroids[cluster])
        withinScatter += d * d
    }
    
    return (betweenScatter / Float(k - 1)) / (withinScatter / Float(n - k))
}

// =======================
// ENHANCED CLUSTERING QUALITY
// =======================

struct EnhancedClusteringQuality {
    let silhouette: Float
    let daviesBouldin: Float?
    let calinskiHarabasz: Float?
    let silhouetteByCluster: [Int: Float]?
    let clusterSizes: [Int]
    let sizeEntropy: Float
    let sizeDeviationPenalty: Float
    let adjacencyPenalty: Float
    let modelScore: Float
    let kPath: [KSelectionPoint]?
    let rebalanceLog: String
    let sizeGini: Float
    let sizeCV: Float
}

// =======================
// COMPREHENSIVE CLUSTERING WITH UNIFIED OBJECTIVE
// =======================

// Main clustering function with all improvements
func autoGroupWithUnifiedObjective(
    urls: [URL],
    windowMs: Double = 256,
    manualK: Int? = nil,
    numInits: Int = 10,
    preprocCfg: PreprocConfig = PreprocConfig(),
    objCfg: ObjectiveConfig = ObjectiveConfig(),
    rebalanceCfg: RebalanceConfig = RebalanceConfig(),
    enableCalibration: Bool = true,
    enableRebalance: Bool = true
) throws -> (
    groups: [[URL]], 
    quality: EnhancedClusteringQuality, 
    selectedK: Int, 
    rebalanceLog: [String],
    state: ClusteringStateEnhanced?
) {
    
    // Extract features
    let features = try urls.map { try extractEnhancedFeatures(from: $0, adaptiveWindow: true) }
    
    // Create feature vectors
    var X = features.map { $0.featureVector }
    
    // Apply z-score normalization
    zscore(&X)
    
    // Apply PCA whitening if configured
    if preprocCfg.usePCAWhitening {
        X = sg_pcaWhitening(vectors: X)
    }
    
    // Determine K range
    let n = urls.count
    let minK = manualK != nil ? max(2, manualK! - 1) : 2
    let maxK = manualK != nil ? min(n/2, manualK! + 1) : min(8, n/2)
    let targetK = manualK ?? Int(sqrt(Float(n)))
    
    var bestScore: Float = -Float.greatestFiniteMagnitude
    var bestState: ClusteringStateEnhanced? = nil
    var bestK = minK
    var kPath: [KSelectionPoint] = []
    
    // Try different K values
    for k in minK...maxK {
        var kBestScore: Float = -Float.greatestFiniteMagnitude
        var kBestLabels: [Int] = []
        
        // Multiple initializations
        for initIndex in 0..<numInits {
            let seed = k * 1000 + initIndex
            let (labels, _) = sg_kMeansEnhanced(vectors: X, k: k, maxIters: 200, seed: seed)
            
            // Compute quality
            let (sil, byCluster, _) = silhouetteGlobalAndByCluster(X: X, y: labels)
            let dbi = daviesBouldin(X: X, y: labels)
            let ch = calinskiHarabasz(X: X, y: labels)
            let counts = enhancedClusterSizes(labels: labels)
            
            let q = EnhancedClusterQuality(sil: sil, dbi: dbi, ch: ch)
            let score = overallQualityScore(q: q, counts: counts, n: n, k: k, kTarget: targetK, cfg: objCfg)
            
            if score > kBestScore {
                kBestScore = score
                kBestLabels = labels
            }
        }
        
        // Create state for best K
        let (cents, _, _) = centroidsGroups(X: X, y: kBestLabels)
        let (sil, byCluster, perSample) = silhouetteGlobalAndByCluster(X: X, y: kBestLabels)
        let state = ClusteringStateEnhanced(
            X: X,
            labels: kBestLabels,
            centroids: cents,
            silGlobal: sil,
            silByCluster: byCluster,
            dbi: daviesBouldin(X: X, y: kBestLabels),
            ch: calinskiHarabasz(X: X, y: kBestLabels)
        )
        
        kPath.append(KSelectionPoint(k: k, score: kBestScore, silhouette: sil, objective: kBestScore, operation: "initial"))
        
        if kBestScore > bestScore {
            bestScore = kBestScore
            bestK = k
            bestState = state
        }
    }
    
    guard var finalState = bestState else {
        throw NSError(domain: "Clustering", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to find valid clustering"])
    }
    
    var rebalanceLog: [String] = []
    
    // Calibrate to manual K if provided
    if enableCalibration, let targetK = manualK {
        rebalanceLog.append("Calibrating from K=\(bestK) to K=\(targetK)")
        finalState = calibrateToK(finalState, kTarget: targetK, objCfg: objCfg)
        
        let counts = enhancedClusterSizes(labels: finalState.labels)
        rebalanceLog.append("After calibration: K=\(counts.count), sizes=\(Array(counts.values).sorted())")
    }
    
    // Rebalance sizes if enabled
    if enableRebalance {
        let (_, _, perSample) = silhouetteGlobalAndByCluster(X: X, y: finalState.labels)
        let margins = computeMargins(X: X, centroids: Array(finalState.centroids.values)).map { $0.margin }
        
        let beforeCounts = enhancedClusterSizes(labels: finalState.labels)
        rebalanceLog.append("Before rebalance: sizes=\(Array(beforeCounts.values).sorted())")
        
        finalState = rebalanceSizes(
            finalState, 
            kTarget: manualK ?? targetK,
            margins: margins,
            sampleSil: perSample,
            objCfg: objCfg,
            cfg: rebalanceCfg
        )
        
        let afterCounts = enhancedClusterSizes(labels: finalState.labels)
        rebalanceLog.append("After rebalance: sizes=\(Array(afterCounts.values).sorted())")
    }
    
    // Convert to URL groups
    var groups: [[URL]] = []
    let clusterIds = Set(finalState.labels).sorted()
    for clusterId in clusterIds {
        let indices = finalState.labels.enumerated().filter { $0.element == clusterId }.map { $0.offset }
        groups.append(indices.map { urls[$0] })
    }
    
    // Create quality report
    let counts = enhancedClusterSizes(labels: finalState.labels)
    let (gini, cv) = sizeInequality(counts: counts)
    
    let quality = EnhancedClusteringQuality(
        silhouette: finalState.silGlobal,
        daviesBouldin: finalState.dbi,
        calinskiHarabasz: finalState.ch,
        silhouetteByCluster: finalState.silByCluster,
        clusterSizes: Array(counts.values).sorted(),
        sizeEntropy: sizeEntropy(Array(counts.values)),
        sizeDeviationPenalty: sizeDeviationPenalty(Array(counts.values), tolerance: 0.25),
        adjacencyPenalty: adjacencyPenalty(
            counts: Array(counts.values), 
            order: clusterOrderBy1D(Array(finalState.centroids.values))
        ),
        modelScore: bestScore,
        kPath: kPath,
        rebalanceLog: rebalanceLog.joined(separator: "\n"),
        sizeGini: gini,
        sizeCV: cv
    )
    
    return (groups, quality, finalState.labels.max()! + 1, rebalanceLog, finalState)
}

// =======================
// ENHANCED CLUSTERING WITH EQUITY
// =======================

// Enhanced clustering with size equity and rebalancing
func autoGroupEnhancedWithEquity(
    urls: [URL],
    windowMs: Double = 256,
    targetK: Int? = nil,
    numRestarts: Int = 20,
    useCapacitated: Bool = true  // Use capacitated vs simple rebalancer
) throws -> (groups: [[URL]], quality: ClusteringQuality, selectedK: Int, rebalanceLog: [String]) {
    
    // Extract enhanced features (reuse from ImprovedSampleSimilarity)
    let features = try urls.map { try extractEnhancedFeatures(from: $0, adaptiveWindow: true) }
    
    // Normalize features
    let normalizedFeatures = sg_normalizeEnhancedFeatures(features)
    
    // Create feature vectors
    let vectors = normalizedFeatures.map { $0.featureVector }
    
    // Apply PCA whitening for better clustering
    let whitenedVectors = sg_pcaWhitening(vectors: vectors)
    
    // Determine K search range
    let minK = targetK != nil ? max(2, targetK! - 1) : 2
    let maxK = targetK != nil ? min(urls.count, targetK! + 2) : min(8, urls.count)
    
    var bestScore: Float = -Float.greatestFiniteMagnitude
    var bestK = minK
    var bestLabels: [Int] = []
    var kPath: [KSelectionPoint] = []
    
    // Quality provider closure
    let qualityProvider: ([Int]) -> Quality = { labels in
        let silhouette = sg_calculateSilhouetteScore(vectors: whitenedVectors, labels: labels)
        let cents = centroids(for: labels, X: whitenedVectors)
        let dbi = sg_calculateDaviesBouldinIndex(vectors: whitenedVectors, labels: labels, centroids: cents)
        let ch = sg_calculateCalinskiHarabaszIndex(vectors: whitenedVectors, labels: labels, centroids: cents)
        return Quality(sil: silhouette, dbi: dbi, ch: ch)
    }
    
    // Try different K values
    for k in minK...maxK {
        var kBestScore: Float = -Float.greatestFiniteMagnitude
        var kBestLabels: [Int] = []
        
        // Multiple restarts for each K
        for restart in 0..<numRestarts {
            let seed = k * 1000 + restart
            let (labels, _) = sg_kMeansEnhanced(vectors: whitenedVectors, k: k, maxIters: 200, seed: seed)
            
            // Calculate quality metrics
            let quality = qualityProvider(labels)
            let cents = centroids(for: labels, X: whitenedVectors)
            let counts = clusterSizes(from: labels)
            let score = modelSelScore(quality: quality, counts: counts, centroids: cents, targetK: targetK)
            
            if score > kBestScore {
                kBestScore = score
                kBestLabels = labels
            }
        }
        
        kPath.append(KSelectionPoint(k: k, score: kBestScore, silhouette: qualityProvider(kBestLabels).sil, objective: kBestScore, operation: "initial"))
        
        if kBestScore > bestScore {
            bestScore = kBestScore
            bestK = k
            bestLabels = kBestLabels
        }
    }
    
    var rebalanceLog: [String] = []
    rebalanceLog.append("Initial K=\(bestK) selected with score=\(String(format: "%.3f", bestScore))")
    
    // K-calibration if target K is specified and different from best K
    if let target = targetK, bestK != target {
        bestLabels = calibrateToKWithEquity(
            targetK: target, 
            labels: bestLabels, 
            vectors: whitenedVectors,
            qualityProvider: qualityProvider,
            log: &rebalanceLog
        )
        bestK = target
    }
    
    // Apply rebalancing
    let initialCounts = clusterSizes(from: bestLabels)
    rebalanceLog.append("Pre-rebalance sizes: \(initialCounts)")
    
    if useCapacitated {
        capacitatedReassign(
            labels: &bestLabels,
            X: whitenedVectors,
            qualityProvider: qualityProvider,
            marginThreshold: 1.25,
            tol: 0.25,
            neighbourBonus: 0.05,
            maxTotalMoves: 6
        )
        rebalanceLog.append("Applied capacitated reassignment")
    } else {
        rebalanceBySize(
            labels: &bestLabels,
            X: whitenedVectors,
            qualityProvider: qualityProvider,
            targetK: targetK,
            marginThreshold: 1.25,
            tolerance: 0.25,
            maxMovesPerPair: 2,
            epsilon: 0.002
        )
        rebalanceLog.append("Applied size rebalancing")
    }
    
    let finalCounts = clusterSizes(from: bestLabels)
    rebalanceLog.append("Post-rebalance sizes: \(finalCounts)")
    
    // Calculate final quality
    let finalQuality = qualityProvider(bestLabels)
    let bestQuality = ClusteringQuality(
        silhouette: finalQuality.sil, 
        daviesBouldin: finalQuality.dbi, 
        calinskiHarabasz: finalQuality.ch
    )
    
    // Group URLs by cluster
    var groups: [[(url: URL, feat: EnhancedSampleFeatures, label: Int)]] = Array(repeating: [], count: bestK)
    for (i, label) in bestLabels.enumerated() {
        groups[label].append((urls[i], features[i], label))
    }
    
    // Sort clusters by median RMS (quietest to loudest)
    let sortedGroups = groups.sorted { 
        sg_medianValue($0.map { $0.feat.rms }) < sg_medianValue($1.map { $0.feat.rms })
    }
    
    // Within each cluster, sort by diversity
    let finalResult = sortedGroups.map { cluster in
        let clusterIndices = cluster.map { item in
            urls.firstIndex(of: item.url)!
        }
        let clusterVectors = clusterIndices.map { whitenedVectors[$0] }
        let sortedIndices = sg_sortByDiversityEnhanced(vectors: clusterVectors)
        return sortedIndices.map { cluster[$0].url }
    }
    
    return (finalResult, bestQuality, bestK, rebalanceLog)
}

// K-calibration with equity objective
func calibrateToKWithEquity(
    targetK: Int, 
    labels: [Int], 
    vectors: [[Float]],
    qualityProvider: ([Int]) -> Quality,
    log: inout [String]
) -> [Int] {
    var workingLabels = labels
    var currentK = Set(labels).count
    
    while currentK != targetK {
        if currentK < targetK {
            workingLabels = splitWorstClusterWithEquity(
                labels: workingLabels, 
                vectors: vectors,
                qualityProvider: qualityProvider,
                log: &log
            )
        } else {
            workingLabels = mergeClosestClustersWithEquity(
                labels: workingLabels, 
                vectors: vectors,
                qualityProvider: qualityProvider,
                log: &log
            )
        }
        currentK = Set(workingLabels).count
    }
    
    return workingLabels
}

func splitWorstClusterWithEquity(
    labels: [Int], 
    vectors: [[Float]],
    qualityProvider: ([Int]) -> Quality,
    log: inout [String]
) -> [Int] {
    let cents = centroids(for: labels, X: vectors)
    let counts = clusterSizes(from: labels)
    let currentScore = modelSelScore(
        quality: qualityProvider(labels),
        counts: counts,
        centroids: cents,
        targetK: nil
    )
    
    // Find best cluster to split
    var bestSplitCluster = -1
    var bestSplitScore = currentScore
    var bestSplitLabels = labels
    
    for (cluster, count) in counts.enumerated() where count >= 4 {
        // Try splitting this cluster
        let clusterIndices = labels.enumerated().filter { $0.element == cluster }.map { $0.offset }
        let clusterVectors = clusterIndices.map { vectors[$0] }
        
        let (subLabels, _) = sg_kMeansEnhanced(vectors: clusterVectors, k: 2, maxIters: 50)
        
        var testLabels = labels
        let newClusterLabel = (labels.max() ?? 0) + 1
        
        for (i, idx) in clusterIndices.enumerated() {
            if subLabels[i] == 1 {
                testLabels[idx] = newClusterLabel
            }
        }
        
        let testCents = centroids(for: testLabels, X: vectors)
        let testCounts = clusterSizes(from: testLabels)
        let testScore = modelSelScore(
            quality: qualityProvider(testLabels),
            counts: testCounts,
            centroids: testCents,
            targetK: nil
        )
        
        if testScore > bestSplitScore {
            bestSplitScore = testScore
            bestSplitCluster = cluster
            bestSplitLabels = testLabels
        }
    }
    
    if bestSplitCluster >= 0 {
        log.append("Split cluster \(bestSplitCluster) (Δscore=\(String(format: "+%.3f", bestSplitScore - currentScore)))")
    }
    
    return bestSplitLabels
}

func mergeClosestClustersWithEquity(
    labels: [Int], 
    vectors: [[Float]],
    qualityProvider: ([Int]) -> Quality,
    log: inout [String]
) -> [Int] {
    let cents = centroids(for: labels, X: vectors)
    let counts = clusterSizes(from: labels)
    let clusters = Array(Set(labels))
    
    guard clusters.count > 1 else { return labels }
    
    let currentScore = modelSelScore(
        quality: qualityProvider(labels),
        counts: counts,
        centroids: cents,
        targetK: nil
    )
    
    // Identify singleton clusters
    let singletons = clusters.filter { cluster in
        counts[clusters.firstIndex(of: cluster)!] == 1
    }
    
    var bestMergeA = -1
    var bestMergeB = -1
    var bestMergeScore = currentScore
    var bestMergeLabels = labels
    
    // Try all merge pairs, prioritizing singletons
    for i in 0..<clusters.count {
        for j in (i+1)..<clusters.count {
            let a = clusters[i]
            let b = clusters[j]
            
            // Skip if neither is singleton and we have singletons
            if !singletons.isEmpty && !singletons.contains(a) && !singletons.contains(b) {
                continue
            }
            
            var testLabels = labels
            for k in 0..<labels.count {
                if labels[k] == b {
                    testLabels[k] = a
                }
            }
            
            let testCents = centroids(for: testLabels, X: vectors)
            let testCounts = clusterSizes(from: testLabels)
            let testScore = modelSelScore(
                quality: qualityProvider(testLabels),
                counts: testCounts,
                centroids: testCents,
                targetK: nil
            )
            
            if testScore > bestMergeScore || (singletons.contains(a) || singletons.contains(b)) {
                bestMergeScore = testScore
                bestMergeA = a
                bestMergeB = b
                bestMergeLabels = testLabels
            }
        }
    }
    
    if bestMergeA >= 0 {
        log.append("Merged clusters \(bestMergeA)←\(bestMergeB) (Δscore=\(String(format: "%+.3f", bestMergeScore - currentScore)))")
    }
    
    return bestMergeLabels
}

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
    
    // Comprehensive diagnostics (optional for backward compatibility)
    let comprehensiveDiagnostics: ComprehensiveAnalysisData?
    
    // Legacy initializer for backward compatibility
    init(windowLengthMs: Double,
         sampleCount: Int,
         samples: [SampleAnalysisData],
         manualGrouping: [Int: [String]],
         automaticGrouping: [Int: [String]],
         comparisonMetrics: ComparisonMetrics?) {
        self.windowLengthMs = windowLengthMs
        self.sampleCount = sampleCount
        self.samples = samples
        self.manualGrouping = manualGrouping
        self.automaticGrouping = automaticGrouping
        self.comparisonMetrics = comparisonMetrics
        self.comprehensiveDiagnostics = nil
    }
    
    // New initializer with comprehensive diagnostics
    init(windowLengthMs: Double,
         sampleCount: Int,
         samples: [SampleAnalysisData],
         manualGrouping: [Int: [String]],
         automaticGrouping: [Int: [String]],
         comparisonMetrics: ComparisonMetrics?,
         comprehensiveDiagnostics: ComprehensiveAnalysisData?) {
        self.windowLengthMs = windowLengthMs
        self.sampleCount = sampleCount
        self.samples = samples
        self.manualGrouping = manualGrouping
        self.automaticGrouping = automaticGrouping
        self.comparisonMetrics = comparisonMetrics
        self.comprehensiveDiagnostics = comprehensiveDiagnostics
    }
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

struct KSelectionPoint: Codable {
    let k: Int
    let score: Float
    let silhouette: Float
    let objective: Float
    let operation: String // "initial", "split", "merge", "rebalance"
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
    let ambiguousSamples: [SampleComparison]?  // Samples with low margin (d2/d1)
    
    // K-selection path
    let kPath: [KSelectionPoint]?  // K values explored during selection
    let selectedK: Int?  // Final selected K
    
    // Equity metrics
    let sizeEntropy: Float?
    let sizeDeviationPenalty: Float?
    let adjacencyPenalty: Float?
    let rebalanceLog: [String]?
    
    // Size inequality metrics
    let clusterSizes: [Int]?
    let sizeGini: Float?
    let sizeCV: Float?
    
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
    private var lastManualGrouping: [Int: [String]]? = nil
    
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
    
    /// Enhanced automatic grouping with unified objective
    @MainActor
    func runAutomaticGroupingEnhanced(
        markers: [Marker],
        audioViewModel: EnhancedAudioViewModel,
        windowMs: Double = 256,
        enableCalibration: Bool = true,
        enableRebalance: Bool = true
    ) -> (grouping: [Int: [String]], analysisData: [SampleAnalysisData], kPath: [KSelectionPoint]?, rebalanceLog: [String]?) {
        
        var analysisResults = analyzeSamples(markers: markers, audioViewModel: audioViewModel, windowMs: windowMs)
        
        // Create URLs for the grouping algorithm
        let tempDir = FileManager.default.temporaryDirectory
        var markerToURL: [String: URL] = [:]
        
        guard let buffer = audioViewModel.sampleBuffer else { return ([:], analysisResults, nil, nil) }
        let sortedMarkers = markers.sorted { $0.samplePosition < $1.samplePosition }
        
        // Create temp files (same as before)
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
                guard regionSamples.count > 0 else { continue }
                
                let audioFile = try AVAudioFile(forWriting: tempURL, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: audioViewModel.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false
                ])
                
                let format = audioFile.processingFormat
                guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(regionSamples.count)) else { continue }
                
                audioBuffer.frameLength = AVAudioFrameCount(regionSamples.count)
                
                if let channelData = audioBuffer.floatChannelData {
                    for (i, sample) in regionSamples.enumerated() {
                        channelData[0][i] = sample
                    }
                    
                    try audioFile.write(from: audioBuffer)
                    markerToURL[marker.id.uuidString] = tempURL
                }
            } catch {
                print("Failed to create audio file for marker \(marker.id): \(error)")
            }
        }
        
        // Run enhanced grouping with unified objective
        let urls = sortedMarkers.compactMap { markerToURL[$0.id.uuidString] }
        let manualK = lastManualGrouping?.count
        
        do {
            let (groups, quality, selectedK, rebalanceLog, state) = try autoGroupWithUnifiedObjective(
                urls: urls,
                windowMs: windowMs,
                manualK: manualK,
                enableCalibration: enableCalibration,
                enableRebalance: enableRebalance
            )
            
            // Log results
            print("\n=== CLUSTERING RESULTS ===")
            print("Selected K: \(selectedK)")
            print(String(format: "Silhouette: %.3f", quality.silhouette))
            if let dbi = quality.daviesBouldin {
                print(String(format: "Davies-Bouldin: %.3f", dbi))
            }
            if let ch = quality.calinskiHarabasz {
                print(String(format: "Calinski-Harabasz: %.1f", ch))
            }
            print("Cluster sizes: \(quality.clusterSizes)")
            print(String(format: "Size Gini: %.3f, CV: %.3f", quality.sizeGini, quality.sizeCV))
            
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
                                distanceToClusterCenter: nil,
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
            
            return (grouping, analysisResults, quality.kPath, rebalanceLog)
            
        } catch {
            print("Error in enhanced grouping: \(error)")
            // Fall back to existing implementation
            let (grouping, analysisData) = runAutomaticGrouping(markers: markers, audioViewModel: audioViewModel, windowMs: windowMs)
            return (grouping, analysisData, nil, nil)
        }
    }
    
    /// Run the automatic grouping algorithm with comprehensive data capture
    @MainActor
    func runAutomaticGroupingWithDiagnostics(
        markers: [Marker],
        audioViewModel: EnhancedAudioViewModel,
        windowMs: Double = 256,
        enableCalibration: Bool = false,
        enableRebalance: Bool = false
    ) -> (grouping: [Int: [String]], 
          analysisData: [SampleAnalysisData], 
          diagnostics: ComprehensiveAnalysisData?) {
        
        let startTime = Date()
        var featureExtractionTime: Double = 0
        let clusteringTime: Double = 0
        let calibrationTime: Double = 0
        let rebalancingTime: Double = 0
        
        var objectiveTrace: [ObjectivePoint] = []
        var rejectedMoves: [RejectedMove] = []
        var adjacencyMislabelsList: [AdjacencyMislabel] = []
        var boundaryAmbiguityList: [BoundaryAmbiguity] = []
        var edgeCasesList: [EdgeCase] = []
        
        // Track feature extraction time
        let featureStart = Date()
        let (grouping, analysisData, kPath, rebalanceLog) = runAutomaticGroupingEnhanced(
            markers: markers,
            audioViewModel: audioViewModel,
            windowMs: windowMs,
            enableCalibration: enableCalibration,
            enableRebalance: enableRebalance
        )
        featureExtractionTime = Date().timeIntervalSince(featureStart) * 1000
        
        // If we have manual grouping for comparison
        if let manualGrouping = lastManualGrouping {
            // Compare groupings with enhanced metrics
            let metrics = compareGroupingsEnhanced(
                manual: manualGrouping,
                automatic: grouping,
                analysisData: analysisData,
                kPath: kPath,
                rebalanceLog: rebalanceLog
            )
            
            // Calculate adjacency mislabels
            let sortedData = analysisData.sorted { $0.samplePosition < $1.samplePosition }
            for i in 0..<sortedData.count-1 {
                let sampleA = sortedData[i]
                let sampleB = sortedData[i+1]
                
                if sampleA.assignedCluster != sampleB.assignedCluster {
                    adjacencyMislabelsList.append(AdjacencyMislabel(
                        sampleIdA: sampleA.id,
                        sampleIdB: sampleB.id,
                        positionA: i,
                        positionB: i+1,
                        clusterA: sampleA.assignedCluster ?? -1,
                        clusterB: sampleB.assignedCluster ?? -1
                    ))
                }
            }
            
            // Calculate boundary ambiguity for each manual group
            for (manualGroup, sampleIds) in manualGrouping {
                let groupSamples = analysisData.filter { sampleIds.contains($0.id) }
                guard !groupSamples.isEmpty else { continue }
                
                // Calculate intra-group RMS
                let groupVectors = groupSamples.compactMap { sample in
                    sample.normalizedTimbreVector.isEmpty ? nil : sample.normalizedTimbreVector
                }
                
                if !groupVectors.isEmpty {
                    let centroid = sg_calculateCentroid(groupVectors)
                    let distances = groupVectors.map { euclid($0, centroid) }
                    let intraGroupRMS = sqrt(distances.map { $0 * $0 }.reduce(0, +) / Float(distances.count))
                    
                    // Find nearest other centroid
                    var minDistToOther: Float = Float.infinity
                    for (otherGroup, otherIds) in manualGrouping where otherGroup != manualGroup {
                        let otherSamples = analysisData.filter { otherIds.contains($0.id) }
                        let otherVectors = otherSamples.compactMap { sample in
                            sample.normalizedTimbreVector.isEmpty ? nil : sample.normalizedTimbreVector
                        }
                        if !otherVectors.isEmpty {
                            let otherCentroid = sg_calculateCentroid(otherVectors)
                            let dist = euclid(centroid, otherCentroid)
                            minDistToOther = min(minDistToOther, dist)
                        }
                    }
                    
                    if minDistToOther < Float.infinity {
                        boundaryAmbiguityList.append(BoundaryAmbiguity(
                            manualGroup: manualGroup,
                            intraGroupRMS: intraGroupRMS,
                            nearestOtherCentroidDist: minDistToOther,
                            ambiguityRatio: intraGroupRMS / minDistToOther
                        ))
                    }
                }
            }
            
            // Extract edge cases from comparison
            edgeCasesList = metrics.detailedComparison.compactMap { sample in
                guard let margin = sample.margin,
                      margin < 1.2 else { return nil }
                
                return EdgeCase(
                    sampleId: sample.sampleId,
                    cluster: sample.autoGroup,
                    nearestCluster: sample.nearestAutoCluster ?? sample.autoGroup,
                    margin: margin,
                    rebalanced: rebalanceLog?.contains(where: { $0.contains(sample.sampleId) }) ?? false
                )
            }
            
            // Track objective trace from K-path
            if let kPath = kPath {
                for (i, point) in kPath.enumerated() {
                    objectiveTrace.append(ObjectivePoint(
                        iteration: i,
                        objective: point.objective,
                        k: point.k,
                        operation: point.operation
                    ))
                }
            }
            
            // Runtime metrics
            let totalTime = Date().timeIntervalSince(startTime) * 1000
            let runtime = RuntimeMetrics(
                totalTimeMs: totalTime,
                featureExtractionMs: featureExtractionTime,
                clusteringMs: clusteringTime,
                calibrationMs: calibrationTime,
                rebalancingMs: rebalancingTime
            )
            
            // Create comprehensive analysis data
            let diagnostics = ComprehensiveAnalysisData(
                comparisonMetrics: metrics,
                objectiveTrace: objectiveTrace.isEmpty ? nil : objectiveTrace,
                rejectedMoves: rejectedMoves.isEmpty ? nil : rejectedMoves,
                adjacencyMislabels: adjacencyMislabelsList.isEmpty ? nil : adjacencyMislabelsList,
                boundaryAmbiguity: boundaryAmbiguityList.isEmpty ? nil : boundaryAmbiguityList,
                edgeCaseList: edgeCasesList.isEmpty ? nil : edgeCasesList,
                paramSweep: nil, // Could be populated during parameter tuning
                bootstrapStats: nil, // Could be populated during bootstrap analysis
                runtime: runtime
            )
            
            return (grouping, analysisData, diagnostics)
        }
        
        return (grouping, analysisData, nil)
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
        
        // Run automatic grouping with enhanced features
        let urls = sortedMarkers.compactMap { markerToURL[$0.id.uuidString] }
        
        // Determine if we have a target K from manual grouping (testing mode)
        let manualK = lastManualGrouping?.count
        
        do {
            let (groups, quality, selectedK, rebalanceLog) = try autoGroupEnhancedWithEquity(
                urls: urls, 
                windowMs: windowMs,
                targetK: manualK,
                numRestarts: 20,
                useCapacitated: true
            )
            
            // Log K selection results
            print("K-Selection: Selected K=\(selectedK), Silhouette=\(quality.silhouette)")
            if let dbi = quality.daviesBouldin {
                print("  Davies-Bouldin: \(dbi)")
            }
            if let ch = quality.calinskiHarabasz {
                print("  Calinski-Harabasz: \(ch)")
            }
            
            // Log rebalancing steps
            print("\nRebalancing Log:")
            for logEntry in rebalanceLog {
                print("  \(logEntry)")
            }
            
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
            
        } catch {
            print("Error in enhanced grouping: \(error)")
            
            // Fall back to basic grouping
            if let groups = try? autoGroupSamplesIntoPseudoVelocityLayers(urls: urls, windowMs: windowMs) {
                var grouping: [Int: [String]] = [:]
                
                // Convert URL groups back to marker IDs
                for (groupIndex, groupURLs) in groups.enumerated() {
                    grouping[groupIndex] = []
                    for url in groupURLs {
                        if let entry = markerToURL.first(where: { $0.value == url }) {
                            grouping[groupIndex]?.append(entry.key)
                        }
                    }
                }
                
                // Clean up temp files
                for url in markerToURL.values {
                    try? FileManager.default.removeItem(at: url)
                }
                
                return (grouping, analysisResults)
            }
        }
        
        // Clean up on failure
        for url in markerToURL.values {
            try? FileManager.default.removeItem(at: url)
        }
        
        return ([:], analysisResults)
    }
    
    /// Store manual grouping for K-calibration in testing mode
    func setManualGrouping(_ grouping: [Int: [String]]) {
        lastManualGrouping = grouping
    }
    
    /// Enhanced comparison with all new metrics
    func compareGroupingsEnhanced(
        manual: [Int: [String]],
        automatic: [Int: [String]],
        analysisData: [SampleAnalysisData],
        kPath: [KSelectionPoint]? = nil,
        rebalanceLog: [String]? = nil
    ) -> ComparisonMetrics {
        // Use existing compareGroupings for base metrics
        let baseMetrics = compareGroupings(manual: manual, automatic: automatic, analysisData: analysisData)
        
        // Calculate size inequality metrics
        let autoSizes = automatic.mapValues { $0.count }
        let (gini, cv) = sizeInequality(counts: autoSizes)
        
        // Extract feature vectors
        let X = analysisData.filter { !$0.normalizedTimbreVector.isEmpty }.map { $0.normalizedTimbreVector }
        let autoLabels = analysisData.filter { !$0.normalizedTimbreVector.isEmpty }.compactMap { sample in
            automatic.first(where: { $0.value.contains(sample.id) })?.key 
        }
        
        // Calculate equity metrics if we have valid data
        let entropy = sizeEntropy(Array(autoSizes.values))
        let devPenalty = sizeDeviationPenalty(Array(autoSizes.values), tolerance: 0.25)
        
        // Calculate adjacency penalty if we have centroids
        var adjPenalty: Float? = nil
        if !X.isEmpty && !autoLabels.isEmpty {
            let (cents, _, _) = centroidsGroups(X: X, y: autoLabels)
            let order = clusterOrderBy1D(Array(cents.values))
            adjPenalty = adjacencyPenalty(counts: Array(autoSizes.values), order: order)
        }
        
        // Return enhanced metrics
        return ComparisonMetrics(
            adjustedRandIndex: baseMetrics.adjustedRandIndex,
            normalizedMutualInfo: baseMetrics.normalizedMutualInfo,
            purityScore: baseMetrics.purityScore,
            silhouetteScore: baseMetrics.silhouetteScore,
            mappedAccuracy: baseMetrics.mappedAccuracy,
            vMeasure: baseMetrics.vMeasure,
            homogeneity: baseMetrics.homogeneity,
            completeness: baseMetrics.completeness,
            b3Precision: baseMetrics.b3Precision,
            b3Recall: baseMetrics.b3Recall,
            b3F1: baseMetrics.b3F1,
            daviesBouldin: baseMetrics.daviesBouldin,
            calinskiHarabasz: baseMetrics.calinskiHarabasz,
            oneToOneAccuracy: baseMetrics.oneToOneAccuracy,
            accuracyGap: baseMetrics.accuracyGap,
            manualClusterCount: baseMetrics.manualClusterCount,
            autoClusterCount: baseMetrics.autoClusterCount,
            samplesScored: baseMetrics.samplesScored,
            totalSamples: baseMetrics.totalSamples,
            coverage: baseMetrics.coverage,
            confusionMatrix: baseMetrics.confusionMatrix,
            labelMapping: baseMetrics.labelMapping,
            perClassPRF1: baseMetrics.perClassPRF1,
            silhouetteByAutoCluster: baseMetrics.silhouetteByAutoCluster,
            silhouetteByManualGroup: baseMetrics.silhouetteByManualGroup,
            merges: baseMetrics.merges,
            splits: baseMetrics.splits,
            ambiguousSamples: baseMetrics.ambiguousSamples,
            kPath: kPath,
            selectedK: automatic.count,
            sizeEntropy: entropy,
            sizeDeviationPenalty: devPenalty,
            adjacencyPenalty: adjPenalty,
            rebalanceLog: rebalanceLog,
            clusterSizes: Array(autoSizes.values).sorted(),
            sizeGini: gini,
            sizeCV: cv,
            detailedComparison: baseMetrics.detailedComparison
        )
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
        
        // Find ambiguous samples (low margin)
        let ambiguousSamples = comparisons.filter { 
            if let margin = $0.margin {
                return margin < 1.3  // Samples where d2/d1 < 1.3 are ambiguous
            }
            return false
        }.sorted { ($0.margin ?? 0) < ($1.margin ?? 0) } // Sort by increasing margin
        
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
            ambiguousSamples: ambiguousSamples.isEmpty ? nil : ambiguousSamples,
            kPath: nil,  // This would need to be passed from the clustering algorithm
            selectedK: Set(autoSampleToGroup.values).count,
            sizeEntropy: nil,  // This would need to be passed from the clustering algorithm
            sizeDeviationPenalty: nil,  // This would need to be passed from the clustering algorithm
            adjacencyPenalty: nil,  // This would need to be passed from the clustering algorithm
            rebalanceLog: nil,  // This would need to be passed from the clustering algorithm
            clusterSizes: nil,  // This would need to be passed from the clustering algorithm
            sizeGini: nil,  // This would need to be passed from the clustering algorithm
            sizeCV: nil,  // This would need to be passed from the clustering algorithm
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
            
            // Size inequality metrics
            print("\nCLUSTER SIZE ANALYSIS:")
            print(String(repeating: "-", count: 60))
            if let sizes = metrics.clusterSizes {
                print("Cluster sizes: \(sizes)")
                if let gini = metrics.sizeGini, let cv = metrics.sizeCV {
                    print(String(format: "Size Gini: %.3f  CV: %.3f", gini, cv))
                }
                if let entropy = metrics.sizeEntropy {
                    print(String(format: "Size Entropy: %.3f", entropy))
                }
                if let devPenalty = metrics.sizeDeviationPenalty {
                    print(String(format: "Size Deviation Penalty: %.3f", devPenalty))
                }
                if let adjPenalty = metrics.adjacencyPenalty {
                    print(String(format: "Adjacency Penalty: %.3f", adjPenalty))
                }
            }
            
            // K-selection path if available
            if let kPath = metrics.kPath, !kPath.isEmpty {
                print("\nK-SELECTION PATH:")
                print(String(repeating: "-", count: 60))
                for point in kPath {
                    let marker = point.k == metrics.selectedK ? " ← selected" : ""
                    print(String(format: "K=%d: score=%.3f, sil=%.3f%@", 
                          point.k, point.score, point.silhouette, marker))
                }
            }
            
            // Rebalance log if available
            if let rebalanceLog = metrics.rebalanceLog, !rebalanceLog.isEmpty {
                print("\nREBALANCE LOG:")
                print(String(repeating: "-", count: 60))
                for entry in rebalanceLog {
                    print(entry)
                }
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
            
            // Report ambiguous samples
            if let ambiguous = metrics.ambiguousSamples, !ambiguous.isEmpty {
                print("\n🔍 AMBIGUOUS SAMPLES (low margin d2/d1 < 1.3):")
                print(String(repeating: "-", count: 50))
                print("Sample Name         Auto  Manual  Margin  Nearest")
                print(String(repeating: "-", count: 50))
                
                for (i, sample) in ambiguous.prefix(10).enumerated() {
                    if let sampleData = session.samples.first(where: { $0.id == sample.sampleId }) {
                        let name = sampleData.name.padding(toLength: 18, withPad: " ", startingAt: 0)
                        let margin = String(format: "%.2f", sample.margin ?? 0).padding(toLength: 6, withPad: " ", startingAt: 0)
                        let nearest = sample.nearestAutoCluster != nil ? String(sample.nearestAutoCluster!) : "-"
                        print("\(name) \(sample.autoGroup)     \(sample.manualGroup)       \(margin)  \(nearest)")
                    }
                }
                
                if ambiguous.count > 10 {
                    print("... and \(ambiguous.count - 10) more ambiguous samples")
                }
                
                print("\n💡 Consider manual review of these samples for correct assignment")
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
        
        // Cluster Size Analysis
        print("\n\nCLUSTER SIZE ANALYSIS:")
        print(String(repeating: "-", count: 60))
        
        // Manual cluster sizes
        var manualSizes: [Int: Int] = [:]
        for (_, samples) in session.manualGrouping {
            manualSizes[samples.count, default: 0] += 1
        }
        
        // Auto cluster sizes
        var autoSizes: [Int: Int] = [:]
        var singletonCount = 0
        for (_, samples) in session.automaticGrouping {
            autoSizes[samples.count, default: 0] += 1
            if samples.count == 1 {
                singletonCount += 1
            }
        }
        
        print("Manual cluster sizes:")
        for (size, count) in manualSizes.sorted(by: { $0.key < $1.key }) {
            print("  Size \(size): \(count) cluster(s)")
        }
        
        print("\nAuto cluster sizes:")
        for (size, count) in autoSizes.sorted(by: { $0.key < $1.key }) {
            let warning = size == 1 ? " ⚠️ (singleton)" : ""
            print("  Size \(size): \(count) cluster(s)\(warning)")
        }
        
        // Calculate and display entropy
        let autoClusterSizes = session.automaticGrouping.values.map { Float($0.count) }
        let totalSamples = autoClusterSizes.reduce(0, +)
        var entropy: Float = 0
        
        for size in autoClusterSizes {
            let p = size / totalSamples
            if p > 0 {
                entropy -= p * log2(p)
            }
        }
        
        // Normalize entropy
        let maxEntropy = log2(Float(session.automaticGrouping.count))
        let normalizedEntropy = maxEntropy > 0 ? entropy / maxEntropy : 0
        
        print(String(format: "\nCluster size entropy: %.3f (normalized: %.3f)", entropy, normalizedEntropy))
        if normalizedEntropy < 0.7 {
            print("⚠️  Low entropy indicates unbalanced cluster sizes")
        }
        
        if singletonCount > 0 {
            print("\n⚠️  \(singletonCount) singleton cluster(s) detected - consider merging")
        }
        
        // K-path exploration (if available)
        if let metrics = session.comparisonMetrics,
           let kPath = metrics.kPath, !kPath.isEmpty {
            print("\n\nK-SELECTION PATH:")
            print(String(repeating: "-", count: 60))
            print("K   Model Score   Silhouette   Selected")
            print(String(repeating: "-", count: 60))
            
            for path in kPath.sorted(by: { $0.k < $1.k }) {
                let selected = path.k == metrics.selectedK ? "✓" : ""
                print(String(format: "%-3d   %8.3f     %8.3f      %@", 
                      path.k, path.score, path.silhouette, selected))
            }
            
            if let selectedK = metrics.selectedK {
                print("\nFinal selected K: \(selectedK)")
            }
        }
        
        // Equity metrics (if available)
        if let metrics = session.comparisonMetrics {
            print("\n\nEQUITY METRICS:")
            print(String(repeating: "-", count: 60))
            
            if let entropy = metrics.sizeEntropy {
                print(String(format: "Size Entropy: %.3f", entropy))
                if entropy < 0.7 {
                    print("  ⚠️ Low entropy - clusters are unbalanced")
                }
            }
            
            if let devPenalty = metrics.sizeDeviationPenalty {
                print(String(format: "Size Deviation Penalty: %.3f", devPenalty))
                if devPenalty > 0.1 {
                    print("  ⚠️ High deviation - some clusters far from target size")
                }
            }
            
            if let adjPenalty = metrics.adjacencyPenalty {
                print(String(format: "Adjacency Penalty: %.3f", adjPenalty))
                if adjPenalty > 0.15 {
                    print("  ⚠️ Large size jumps between adjacent clusters")
                }
            }
            
            // Rebalancing log
            if let rebalanceLog = metrics.rebalanceLog, !rebalanceLog.isEmpty {
                print("\nREBALANCING LOG:")
                print(String(repeating: "-", count: 60))
                for entry in rebalanceLog {
                    print("• \(entry)")
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
        
        for (_, vector) in X.enumerated() {
            var distances: [(cluster: Int, dist: Float)] = []
            
            for (cluster, centroid) in centroids {
                let dist = euclid(vector, centroid)
                distances.append((cluster, dist))
            }
            
            distances.sort { $0.dist < $1.dist }
            
            let nearest = distances[0].cluster
            let secondNearest = distances.count > 1 ? distances[1].cluster : nil
            let margin: Float
            if distances.count > 1 && distances[0].dist > 0 {
                margin = distances[1].dist / distances[0].dist
            } else {
                // Use a large but finite value instead of infinity for JSON compatibility
                margin = 999.0
            }
            
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
                // Simple quality score based on silhouette
                let score = next.quality.silhouetteGlobal
                
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
                    centroids[c] = sg_calculateCentroid(members)
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

// MARK: - Parameter Sensitivity Analysis

extension SpectralGroupingAnalyzer {
    
    /// Perform bootstrap parameter sensitivity analysis
    func parameterSensitivityCheck(
        vectors: [[Float]],
        sampleIds: [String],
        manualLabels: [String: Int],
        kTarget: Int,
        cfg: ObjectiveConfig = ObjectiveConfig(),
        nBootstrap: Int = 10
    ) -> ParameterSensitivity {
        var stabilityScores: [Float] = []
        var kVariations: [Int] = []
        var objectiveTraces: [[Float]] = []
        
        // Original clustering
        let (origLabels, origCentroids) = sg_kMeansEnhanced(vectors: vectors, k: kTarget, maxIters: 100)
        let origLabelsById = Dictionary(uniqueKeysWithValues: zip(sampleIds, origLabels))
        
        for i in 0..<nBootstrap {
            // Add ±5% Gaussian noise to features
            var noisyVectors = vectors
            addGaussianNoise(&noisyVectors, scale: 0.05)
            
            // Recluster with noisy features
            let (noisyLabels, _) = sg_kMeansEnhanced(vectors: noisyVectors, k: kTarget, maxIters: 100)
            let noisyLabelsById = Dictionary(uniqueKeysWithValues: zip(sampleIds, noisyLabels))
            
            // Compare stability (ARI between original and noisy clustering)
            let stability = calculateAdjustedRandIndex(
                manual: origLabelsById,
                auto: noisyLabelsById
            )
            stabilityScores.append(stability)
            
            // Try K-calibration on noisy data
            let state = ClusteringState(
                labelsById: noisyLabelsById,
                vectorsById: Dictionary(uniqueKeysWithValues: zip(sampleIds, noisyVectors)),
                quality: ClusterQuality(silhouetteGlobal: 0, daviesBouldin: nil, calinskiHarabasz: nil),
                centroids: [:],
                silhouetteByCluster: [:]
            )
            
            let (calibratedK, objTrace) = performSensitivityKCalibration(
                state: state,
                kTarget: kTarget,
                cfg: cfg
            )
            kVariations.append(calibratedK)
            objectiveTraces.append(objTrace)
        }
        
        return ParameterSensitivity(
            meanStability: stabilityScores.reduce(0, +) / Float(stabilityScores.count),
            stdStability: calculateStd(stabilityScores),
            kConsensus: mode(kVariations) ?? kTarget,
            kVariations: kVariations,
            objectiveTraces: objectiveTraces
        )
    }
    
    private func addGaussianNoise(_ vectors: inout [[Float]], scale: Float) {
        for i in 0..<vectors.count {
            for j in 0..<vectors[i].count {
                // Box-Muller transform for Gaussian noise
                let u1 = Float.random(in: 0..<1)
                let u2 = Float.random(in: 0..<1)
                let z0 = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
                vectors[i][j] += z0 * scale * vectors[i][j]
            }
        }
    }
    
    private func performSensitivityKCalibration(
        state: ClusteringState,
        kTarget: Int,
        cfg: ObjectiveConfig
    ) -> (Int, [Float]) {
        var objTrace: [Float] = []
        var currentK = kTarget
        
        // Simple K adjustment for sensitivity test
        for k in max(2, kTarget-1)...min(kTarget+1, state.vectorsById.count/2) {
            let vectors = Array(state.vectorsById.values)
            let (labels, centroids) = sg_kMeansEnhanced(vectors: vectors, k: k, maxIters: 50)
            
            let q = calculateQuickQuality(vectors: vectors, labels: labels, centroids: centroids)
            let counts = Dictionary(grouping: labels, by: { $0 }).mapValues { $0.count }
            let mappedCounts = counts
            
            let obj = AbletonTest.overallQualityScore(
                q: EnhancedClusterQuality(
                    sil: q.silhouetteGlobal,
                    dbi: q.daviesBouldin,
                    ch: q.calinskiHarabasz
                ),
                counts: mappedCounts,
                n: vectors.count,
                k: k,
                kTarget: kTarget,
                labels: nil,
                cfg: cfg
            )
            
            objTrace.append(obj)
            if obj > objTrace.max() ?? -Float.infinity {
                currentK = k
            }
        }
        
        return (currentK, objTrace)
    }
    
    private func calculateQuickQuality(
        vectors: [[Float]],
        labels: [Int],
        centroids: [[Float]]
    ) -> ClusterQuality {
        let sil = silhouetteGlobalAndByCluster(X: vectors, y: labels).global
        let dbi = daviesBouldin(X: vectors, y: labels)
        let ch = calinskiHarabasz(X: vectors, y: labels)
        
        return ClusterQuality(
            silhouetteGlobal: sil,
            daviesBouldin: dbi,
            calinskiHarabasz: ch
        )
    }
    
    private func calculateStd(_ values: [Float]) -> Float {
        let mean = values.reduce(0, +) / Float(values.count)
        let variance = values.map { pow($0 - mean, 2) }.reduce(0, +) / Float(values.count)
        return sqrt(variance)
    }
    
    private func mode<T: Hashable>(_ array: [T]) -> T? {
        let counts = Dictionary(grouping: array, by: { $0 }).mapValues { $0.count }
        return counts.max(by: { $0.value < $1.value })?.key
    }
}

// MARK: - Comprehensive Data Capture

struct ComprehensiveAnalysisData: Codable {
    // Core metrics
    let comparisonMetrics: ComparisonMetrics
    
    // Additional diagnostic data
    let objectiveTrace: [ObjectivePoint]?
    let rejectedMoves: [RejectedMove]?
    let adjacencyMislabels: [AdjacencyMislabel]?
    let boundaryAmbiguity: [BoundaryAmbiguity]?
    let edgeCaseList: [EdgeCase]?
    let paramSweep: ParameterSweep?
    let bootstrapStats: BootstrapStatistics?
    let runtime: RuntimeMetrics?
}

struct ObjectivePoint: Codable {
    let iteration: Int
    let objective: Float
    let k: Int
    let operation: String // "initial", "split", "merge", "rebalance"
}

struct RejectedMove: Codable {
    let sampleId: String
    let fromCluster: Int
    let toCluster: Int
    let reason: String // "worsens_objective", "increases_imbalance", etc.
    let objectiveChange: Float
}

struct AdjacencyMislabel: Codable {
    let sampleIdA: String
    let sampleIdB: String
    let positionA: Int
    let positionB: Int
    let clusterA: Int
    let clusterB: Int
}

struct BoundaryAmbiguity: Codable {
    let manualGroup: Int
    let intraGroupRMS: Float
    let nearestOtherCentroidDist: Float
    let ambiguityRatio: Float
}

struct EdgeCase: Codable {
    let sampleId: String
    let cluster: Int
    let nearestCluster: Int
    let margin: Float // d2/d1
    let rebalanced: Bool
}

struct ParameterSweep: Codable {
    let parameter: String
    let values: [Float]
    let objectives: [Float]
    let selectedValue: Float
}

struct BootstrapStatistics: Codable {
    let meanStability: Float
    let stdStability: Float
    let kConsensus: Int
    let kDistribution: [Int: Int] // k value -> count
}

struct RuntimeMetrics: Codable {
    let totalTimeMs: Double
    let featureExtractionMs: Double
    let clusteringMs: Double
    let calibrationMs: Double
    let rebalancingMs: Double
}

struct ParameterSensitivity {
    let meanStability: Float
    let stdStability: Float
    let kConsensus: Int
    let kVariations: [Int]
    let objectiveTraces: [[Float]]
}

extension SpectralGroupingAnalyzer {
    
    /// Capture comprehensive analysis data during clustering
    func captureComprehensiveData(
        during operation: () -> (ComparisonMetrics, [ObjectivePoint], [RejectedMove]),
        withTiming: Bool = true
    ) -> ComprehensiveAnalysisData {
        let startTime = Date()
        var featureTime: Double = 0
        var clusterTime: Double = 0
        var calibrationTime: Double = 0
        var rebalanceTime: Double = 0
        
        // Run the main operation
        let (metrics, objTrace, rejectedMoves) = operation()
        
        // Calculate adjacency mislabels
        let adjacencyMislabels = findAdjacencyMislabels(from: metrics)
        
        // Calculate boundary ambiguity
        let boundaryAmbiguity = calculateBoundaryAmbiguityData(from: metrics)
        
        // Extract edge cases
        let edgeCases = extractEdgeCases(from: metrics)
        
        // Parameter sweep (if applicable)
        let paramSweep: ParameterSweep? = nil // Can be populated during parameter tuning
        
        // Bootstrap statistics (if applicable)
        let bootstrapStats: BootstrapStatistics? = nil // Can be populated during bootstrap analysis
        
        // Runtime metrics
        let totalTime = Date().timeIntervalSince(startTime) * 1000
        let runtime = RuntimeMetrics(
            totalTimeMs: totalTime,
            featureExtractionMs: featureTime,
            clusteringMs: clusterTime,
            calibrationMs: calibrationTime,
            rebalancingMs: rebalanceTime
        )
        
        return ComprehensiveAnalysisData(
            comparisonMetrics: metrics,
            objectiveTrace: objTrace.isEmpty ? nil : objTrace,
            rejectedMoves: rejectedMoves.isEmpty ? nil : rejectedMoves,
            adjacencyMislabels: adjacencyMislabels.isEmpty ? nil : adjacencyMislabels,
            boundaryAmbiguity: boundaryAmbiguity.isEmpty ? nil : boundaryAmbiguity,
            edgeCaseList: edgeCases.isEmpty ? nil : edgeCases,
            paramSweep: paramSweep,
            bootstrapStats: bootstrapStats,
            runtime: withTiming ? runtime : nil
        )
    }
    
    private func findAdjacencyMislabels(from metrics: ComparisonMetrics) -> [AdjacencyMislabel] {
        var mislabels: [AdjacencyMislabel] = []
        
        // Sort samples by position
        let sortedSamples = metrics.detailedComparison.sorted { a, b in
            // Extract position from sample ID if possible
            let posA = Int(a.sampleId.components(separatedBy: "_").last ?? "0") ?? 0
            let posB = Int(b.sampleId.components(separatedBy: "_").last ?? "0") ?? 0
            return posA < posB
        }
        
        // Check adjacent pairs
        for i in 0..<sortedSamples.count-1 {
            let sampleA = sortedSamples[i]
            let sampleB = sortedSamples[i+1]
            
            if sampleA.autoGroup != sampleB.autoGroup {
                mislabels.append(AdjacencyMislabel(
                    sampleIdA: sampleA.sampleId,
                    sampleIdB: sampleB.sampleId,
                    positionA: i,
                    positionB: i+1,
                    clusterA: sampleA.autoGroup,
                    clusterB: sampleB.autoGroup
                ))
            }
        }
        
        return mislabels
    }
    
    private func calculateBoundaryAmbiguityData(from metrics: ComparisonMetrics) -> [BoundaryAmbiguity] {
        // This would need access to the actual feature vectors and centroids
        // For now, return empty array - would be populated during actual analysis
        return []
    }
    
    private func extractEdgeCases(from metrics: ComparisonMetrics) -> [EdgeCase] {
        return metrics.detailedComparison.compactMap { sample in
            guard let margin = sample.margin,
                  margin < 1.2 else { return nil }
            
            return EdgeCase(
                sampleId: sample.sampleId,
                cluster: sample.autoGroup,
                nearestCluster: sample.nearestAutoCluster ?? sample.autoGroup,
                margin: margin,
                rebalanced: false // Would be updated during rebalancing
            )
        }
    }
}