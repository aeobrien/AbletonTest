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
        guard let session = session else {
            throw CocoaError(.fileWriteUnknown)
        }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        let data = try encoder.encode(session)
        return FileWrapper(regularFileWithContents: data)
    }
}