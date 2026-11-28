import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Export XML View

struct ExportXMLView: View {
    let xmlContent: String
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 15) {
            Text("Generated Ableton Sampler XML")
                .font(.title2)
                .padding(.top)
            
            // Use TextEditor for scrollable and selectable text content
            TextEditor(text: .constant(xmlContent))
                .font(.system(.body, design: .monospaced))
                .border(Color.gray.opacity(0.5), width: 1)
                .padding(.horizontal)
                .frame(minHeight: 200, maxHeight: .infinity)
            
            HStack {
                Button("Copy to Clipboard") {
                    copyToClipboard(text: xmlContent)
                }
                
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom)
        }
        .padding()
        .frame(minWidth: 600, minHeight: 400)
    }
    
    private func copyToClipboard(text: String) {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #endif
    }
}