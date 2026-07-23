import SwiftUI

struct RootView: View {
    var body: some View {
        NavigationStack {
            Color.clear
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("library.root")
        }
    }
}

#Preview {
    RootView()
}
