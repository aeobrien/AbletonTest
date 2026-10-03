import SwiftUI

// Debug overlay to show touch/click events
struct DebugOverlay: View {
    @Binding var lastEvent: String
    @Binding var eventCount: Int
    
    var body: some View {
        VStack(alignment: .leading) {
            Text("Debug Info")
                .font(.caption.bold())
            Text("Events: \(eventCount)")
                .font(.caption)
            Text("Last: \(lastEvent)")
                .font(.caption)
                .lineLimit(2)
        }
        .padding(6)
        .background(Color.black.opacity(0.7))
        .foregroundColor(.white)
        .cornerRadius(4)
    }
}

// Extension to add debug tracking to views
extension View {
    func debugInteractions(_ label: String, lastEvent: Binding<String>, eventCount: Binding<Int>) -> some View {
        self
            .onTapGesture { location in
                lastEvent.wrappedValue = "\(label) tap at \(Int(location.x)),\(Int(location.y))"
                eventCount.wrappedValue += 1
                print("DEBUG: \(lastEvent.wrappedValue)")
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        lastEvent.wrappedValue = "\(label) drag at \(Int(value.location.x)),\(Int(value.location.y))"
                        eventCount.wrappedValue += 1
                        print("DEBUG: \(lastEvent.wrappedValue)")
                    }
            )
    }
}