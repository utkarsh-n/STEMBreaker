import SwiftUI
import StemCore

enum InstrumentTheme {
    static let background = Color(red: 0.055, green: 0.06, blue: 0.055)
    static let panel = Color(red: 0.10, green: 0.11, blue: 0.10)
    static let ink = Color(red: 0.94, green: 0.94, blue: 0.86)
    static let quiet = Color(red: 0.58, green: 0.61, blue: 0.56)
    static let accents: [Color] = [Color(red: 0.98, green: 0.49, blue: 0.37), Color(red: 0.82, green: 0.93, blue: 0.44), Color(red: 0.49, green: 0.80, blue: 0.96), Color(red: 0.77, green: 0.64, blue: 0.94)]
}

extension StemChannel {
    var shortName: String { ["VOX", "DRUMS", "BASS", "MUSIC"][rawValue] }
    var displayName: String { ["Vocals", "Drums", "Bass", "Other music"][rawValue] }
    var tint: Color { InstrumentTheme.accents[rawValue] }
}

struct TechnicalLabel: View {
    var text: String
    var color: Color = InstrumentTheme.quiet
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium, design: .monospaced))
            .tracking(1.2).foregroundStyle(color)
    }
}

func timecode(_ time: Double) -> String {
    let safe = time.isFinite ? max(0, Int(time)) : 0
    return String(format: "%02d:%02d", safe / 60, safe % 60)
}
