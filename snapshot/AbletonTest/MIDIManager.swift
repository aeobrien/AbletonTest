import Foundation
import CoreMIDI
import os.log

// MARK: - MIDI Device Info

struct MIDIDeviceInfo: Identifiable {
    let id: MIDIEndpointRef
    let name: String
}

// MARK: - MIDI Manager

/// Manages MIDI connections and messaging
class MIDIManager: ObservableObject {
    @Published var midiDestinations: [MIDIDeviceInfo] = []
    @Published var isConnected = false
    
    private var midiClient: MIDIClientRef = 0
    private var outputPort: MIDIPortRef = 0
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AbletonTest", category: "MIDIManager")
    
    init() {
        setupMIDI()
    }
    
    deinit {
        if outputPort != 0 {
            MIDIPortDispose(outputPort)
        }
        if midiClient != 0 {
            MIDIClientDispose(midiClient)
        }
    }
    
    // MARK: - Setup
    
    private func setupMIDI() {
        // Create MIDI client
        let clientName = "AbletonTest" as CFString
        let status = MIDIClientCreateWithBlock(clientName, &midiClient) { notification in
            // Handle MIDI setup changes
            self.handleMIDINotification(notification)
        }
        
        if status == noErr {
            logger.info("MIDI client created successfully")
            
            // Create output port
            let portName = "AbletonTest Output" as CFString
            let portStatus = MIDIOutputPortCreate(midiClient, portName, &outputPort)
            
            if portStatus == noErr {
                logger.info("MIDI output port created successfully")
                isConnected = true
                refreshDestinations()
            } else {
                logger.error("Failed to create MIDI output port: \(portStatus)")
            }
        } else {
            logger.error("Failed to create MIDI client: \(status)")
        }
    }
    
    // MARK: - Destination Management
    
    func refreshDestinations() {
        var destinations: [MIDIDeviceInfo] = []
        
        let destCount = MIDIGetNumberOfDestinations()
        for i in 0..<destCount {
            let endpoint = MIDIGetDestination(i)
            if let name = getEndpointName(endpoint) {
                destinations.append(MIDIDeviceInfo(id: endpoint, name: name))
            }
        }
        
        DispatchQueue.main.async {
            self.midiDestinations = destinations
            self.logger.info("Found \(destinations.count) MIDI destinations")
        }
    }
    
    private func getEndpointName(_ endpoint: MIDIEndpointRef) -> String? {
        var name: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
        
        if status == noErr, let name = name {
            return name.takeRetainedValue() as String
        }
        return nil
    }
    
    // MARK: - MIDI Messaging
    
    func sendMIDIMessage(data: [UInt8], to destination: MIDIEndpointRef) {
        guard outputPort != 0 else {
            logger.error("No output port available")
            return
        }
        
        var packet = MIDIPacket()
        packet.timeStamp = 0
        packet.length = UInt16(data.count)
        
        for (index, byte) in data.enumerated() where index < 256 {
            withUnsafeMutablePointer(to: &packet.data.0) { ptr in
                ptr.advanced(by: index).pointee = byte
            }
        }
        
        var packetList = MIDIPacketList(numPackets: 1, packet: packet)
        let status = MIDISend(outputPort, destination, &packetList)
        
        if status != noErr {
            logger.error("Failed to send MIDI message: \(status)")
        }
    }
    
    func sendNoteOn(note: UInt8, velocity: UInt8, channel: UInt8 = 0, to destination: MIDIEndpointRef) {
        let status = 0x90 | (channel & 0x0F)
        let data: [UInt8] = [status, note, velocity]
        sendMIDIMessage(data: data, to: destination)
    }
    
    func sendNoteOff(note: UInt8, velocity: UInt8 = 0, channel: UInt8 = 0, to destination: MIDIEndpointRef) {
        let status = 0x80 | (channel & 0x0F)
        let data: [UInt8] = [status, note, velocity]
        sendMIDIMessage(data: data, to: destination)
    }
    
    // MARK: - Notification Handling
    
    private func handleMIDINotification(_ notification: UnsafePointer<MIDINotification>) {
        switch notification.pointee.messageID {
        case .msgSetupChanged:
            logger.info("MIDI setup changed")
            DispatchQueue.main.async {
                self.refreshDestinations()
            }
        case .msgObjectAdded:
            logger.info("MIDI object added")
            DispatchQueue.main.async {
                self.refreshDestinations()
            }
        case .msgObjectRemoved:
            logger.info("MIDI object removed")
            DispatchQueue.main.async {
                self.refreshDestinations()
            }
        default:
            break
        }
    }
}