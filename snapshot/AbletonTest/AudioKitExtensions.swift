import Foundation
import AVFoundation
import Accelerate

// MARK: - SampleBuffer implementation
public final class SampleBuffer: Sendable {
    let samples: [Float]
    
    public init(samples: [Float]) {
        self.samples = samples
    }
    
    public var count: Int {
        samples.count
    }
}

// MARK: - AVAudioFile extension for float data extraction
extension AVAudioFile {
    /// Converts to a 32 bit PCM buffer
    func toAVAudioPCMBuffer() -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat,
                                           frameCapacity: AVAudioFrameCount(length)) else { return nil }
        
        do {
            framePosition = 0
            try read(into: buffer)
        } catch {
            print("Cannot read into buffer: \(error.localizedDescription)")
            return nil
        }
        
        return buffer
    }
    
    /// Converts to Swift friendly Float array
    public func floatChannelData() -> [[Float]]? {
        guard let pcmBuffer = toAVAudioPCMBuffer() else { return nil }
        
        // Extract float channel data
        guard let floatChannelData = pcmBuffer.floatChannelData else { return nil }
        
        let channelCount = Int(pcmBuffer.format.channelCount)
        let frameLength = Int(pcmBuffer.frameLength)
        let stride = pcmBuffer.stride
        
        var result: [[Float]] = []
        
        for channel in 0..<channelCount {
            var channelData: [Float] = []
            channelData.reserveCapacity(frameLength)
            
            for sampleIndex in 0..<frameLength {
                channelData.append(floatChannelData[channel][sampleIndex * stride])
            }
            result.append(channelData)
        }
        
        return result
    }
}