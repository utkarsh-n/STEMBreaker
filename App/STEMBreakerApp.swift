import SwiftUI

@main
struct STEMBreakerApp: App {
    @State private var deck = DeckStore()
    var body: some Scene {
        WindowGroup {
            InstrumentView(deck: deck)
                .preferredColorScheme(.dark)
                .task { await deck.prepare() }
        }
    }
}
