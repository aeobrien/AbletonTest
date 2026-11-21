import SwiftUI

// Test view to verify button functionality
struct TestButtonView: View {
    @State private var buttonClickCount = 0
    @State private var tapLocation: CGPoint = .zero
    @State private var dragLocation: CGPoint = .zero
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Button Test")
                .font(.title)
            
            // Test button similar to the transient detection button
            Button(action: {
                buttonClickCount += 1
                print(">>> TEST BUTTON CLICKED: \(buttonClickCount) <<<")
            }) {
                Text("Test Button (\(buttonClickCount))")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            
            // Test tap gesture area
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(height: 100)
                .overlay(
                    Text("Tap here: \(Int(tapLocation.x)), \(Int(tapLocation.y))")
                        .foregroundColor(.white)
                )
                .onTapGesture { location in
                    tapLocation = location
                    print(">>> TAP DETECTED at: \(location) <<<")
                }
            
            // Test drag gesture area
            Rectangle()
                .fill(Color.blue.opacity(0.2))
                .frame(height: 100)
                .overlay(
                    Text("Drag here: \(Int(dragLocation.x)), \(Int(dragLocation.y))")
                        .foregroundColor(.white)
                )
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragLocation = value.location
                            print(">>> DRAG at: \(value.location) <<<")
                        }
                )
        }
        .padding()
    }
}

// Preview for testing
struct TestButtonView_Previews: PreviewProvider {
    static var previews: some View {
        TestButtonView()
    }
}