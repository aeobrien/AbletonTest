import SwiftUI

// Simplified Waveform view for initial integration
struct Waveform: View {
    let samples: SampleBuffer
    var start: Int = 0
    var length: Int = 0
    
    @State private var cachedSamples: [Float] = []
    @State private var cachedStart: Int = -1
    @State private var cachedLength: Int = -1
    
    private var actualLength: Int {
        if length > 0 {
            return min(length, samples.count - start)
        } else {
            return samples.count - start
        }
    }
    
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                // Use cached samples if available and still valid
                let samplesToDisplay: [Float]
                if cachedStart == start && cachedLength == length && !cachedSamples.isEmpty {
                    samplesToDisplay = cachedSamples
                } else {
                    samplesToDisplay = calculateDisplaySamples(for: Int(size.width))
                }
                
                guard !samplesToDisplay.isEmpty else { return }
                
                let midY = size.height / 2
                let step = size.width / CGFloat(samplesToDisplay.count - 1)
                
                // Create waveform path
                var path = Path()
                
                for i in samplesToDisplay.indices {
                    let x = CGFloat(i) * step
                    let amplitude = CGFloat(samplesToDisplay[i]) * midY * 0.9 // 90% to avoid clipping
                    
                    // Only draw if there's actual signal
                    let displayAmplitude = amplitude
                    
                    // Skip drawing if amplitude is essentially zero
                    if displayAmplitude < 0.001 {
                        continue
                    }
                    
                    path.move(to: CGPoint(x: x, y: midY - displayAmplitude))
                    path.addLine(to: CGPoint(x: x, y: midY + displayAmplitude))
                }
                
                context.stroke(path, with: .color(.blue), lineWidth: 1)
            }
        }
        .onAppear {
            updateCache()
        }
        .onChange(of: start) { updateCache() }
        .onChange(of: length) { updateCache() }
    }
    
    private func updateCache() {
        cachedSamples = calculateDisplaySamples(for: 1000)
        cachedStart = start
        cachedLength = length
    }
    
    private func calculateDisplaySamples(for targetPoints: Int) -> [Float] {
        guard actualLength > 0 else {
            return []
        }
        
        let endIndex = min(start + actualLength, samples.count)
        let sampleRange = Array(samples.samples[start..<endIndex])
        
        if sampleRange.count <= targetPoints {
            // Use all samples if we have fewer than target
            return sampleRange.map { abs($0) }
        } else {
            // Downsample for display
            let step = Float(sampleRange.count) / Float(targetPoints)
            return (0..<targetPoints).map { i in
                let index = Int(Float(i) * step)
                return abs(sampleRange[min(index, sampleRange.count - 1)])
            }
        }
    }
    
    func foregroundColor(_ color: Color) -> some View {
        self.overlay(
            GeometryReader { geometry in
                Canvas { context, size in
                    // Calculate display samples
                    let samplesToDisplay: [Float]
                    if cachedStart == start && cachedLength == length && !cachedSamples.isEmpty {
                        samplesToDisplay = cachedSamples
                    } else {
                        samplesToDisplay = calculateDisplaySamples(for: Int(size.width))
                    }
                    
                    guard !samplesToDisplay.isEmpty else { return }
                    
                    let midY = size.height / 2
                    let step = size.width / CGFloat(samplesToDisplay.count - 1)
                    
                    var path = Path()
                    
                    for i in samplesToDisplay.indices {
                        let x = CGFloat(i) * step
                        let amplitude = CGFloat(samplesToDisplay[i]) * midY * 0.9
                        
                        // Only draw if there's actual signal
                        let displayAmplitude = amplitude
                        
                        // Skip drawing if amplitude is essentially zero
                        if displayAmplitude < 0.001 {
                            continue
                        }
                        
                        path.move(to: CGPoint(x: x, y: midY - displayAmplitude))
                        path.addLine(to: CGPoint(x: x, y: midY + displayAmplitude))
                    }
                    
                    context.stroke(path, with: .color(color), lineWidth: 1)
                }
            }
        )
    }
}