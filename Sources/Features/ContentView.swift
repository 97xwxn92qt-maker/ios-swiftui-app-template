import SwiftUI

/// Minimal starter screen — replace with your app. It exists so the template
/// builds, runs, and ships an IPA out of the box.
struct ContentView: View {
  @State private var taps = 0

  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        Image(systemName: "swift")
          .font(.system(size: 72))
          .foregroundStyle(.tint)
          .symbolEffect(.bounce, value: taps)

        Text("Hello, iOS 👋")
          .font(.largeTitle.bold())

        Text("You tapped \(taps) time\(taps == 1 ? "" : "s").")
          .foregroundStyle(.secondary)
          .contentTransition(.numericText())

        Button("Tap me") {
          withAnimation(.snappy) { taps += 1 }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
      }
      .padding()
      .navigationTitle("AppName")
    }
  }
}

#Preview {
  ContentView()
}
