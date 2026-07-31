import SwiftUI

struct ZoneChoiceView: View {
    let onChoice: (Bool) -> Void
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.blue)
            
            Text("How would you like to work with this audio file?")
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
            
            VStack(spacing: 16) {
                Button(action: {
                    onChoice(false)
                    dismiss()
                }) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Use Whole File", systemImage: "doc.fill")
                            .font(.headline)
                        Text("Work with the entire audio file as a single recording")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    onChoice(true)
                    dismiss()
                }) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Split into Zones", systemImage: "square.split.2x1.fill")
                            .font(.headline)
                        Text("Divide the file into multiple zones for separate sounds")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
            
            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(width: 450)
    }
}