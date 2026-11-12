import SwiftUI
import UniformTypeIdentifiers

struct TestSessionDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    
    let session: GroupingTestSession?
    
    init(session: GroupingTestSession?) {
        self.session = session
    }
    
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        session = try JSONDecoder().decode(GroupingTestSession.self, from: data)
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        print("=== TestSessionDocument.fileWrapper called ===")
        print("Session is nil: \(session == nil)")
        
        guard let session = session else {
            print("ERROR: Session is nil, throwing fileWriteUnknown error")
            throw CocoaError(.fileWriteUnknown)
        }
        
        print("Session ID: \(session.id)")
        print("Sample count: \(session.sampleCount)")
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        do {
            let data = try encoder.encode(session)
            print("Successfully encoded session, data size: \(data.count) bytes")
            let wrapper = FileWrapper(regularFileWithContents: data)
            print("Created FileWrapper successfully")
            return wrapper
        } catch {
            print("ERROR: Failed to encode session")
            print("Encoding error: \(error)")
            print("Error type: \(type(of: error))")
            throw error
        }
    }
}