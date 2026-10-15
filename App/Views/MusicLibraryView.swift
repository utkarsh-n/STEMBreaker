import SwiftUI
import MediaPlayer

struct MusicLibraryView: View {
    var deck: DeckStore
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss
    private var filteredSongs: [MPMediaItem] {
        if search.isEmpty { return deck.music.songs }
        return deck.music.songs.filter { "\($0.title ?? "") \($0.artist ?? "")".localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if deck.music.authorizationStatus != .authorized {
                    ContentUnavailableView {
                        Label("Your listening library", systemImage: "music.note.list")
                    } description: {
                        Text("Connect to browse your Apple Music library and follow the song playing in Music. Protected songs stay in Apple Music.")
                    } actions: {
                        if deck.music.authorizationStatus == .denied || deck.music.authorizationStatus == .restricted {
                            Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }.buttonStyle(.borderedProminent)
                        } else {
                            Button("Connect Apple Music") { Task { await deck.music.connect() } }.buttonStyle(.borderedProminent).accessibilityIdentifier("connect-music")
                        }
                        if let error = deck.music.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("library-error") }
                    }
                } else if deck.music.isLoading {
                    ProgressView("Reading library…")
                } else {
                    List {
                        if let current = deck.music.currentItem {
                            Section("Playing in Music") { songRow(current, current: true) }
                        }
                        Section("Your songs · \(deck.music.songs.count)") {
                            ForEach(filteredSongs, id: \.persistentID) { song in songRow(song, current: false) }
                        }
                        if filteredSongs.isEmpty {
                            ContentUnavailableView(search.isEmpty ? "No songs in your library" : "No matches", systemImage: "music.note", description: Text(search.isEmpty ? "Add songs to your library in Apple Music, then refresh." : "Try another title or artist."))
                        }
                        if let error = deck.music.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
                    }
                    .searchable(text: $search, prompt: "Song or artist")
                    .refreshable { await deck.music.connect() }
                }
            }
            .navigationTitle("Apple Music").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(InstrumentTheme.accents[0])
        .task { if deck.music.authorizationStatus == .authorized { await deck.music.connect() } }
    }

    private func songRow(_ song: MPMediaItem, current: Bool) -> some View {
        Button {
            deck.engine.pause(); deck.microphone.stop()
            deck.changeSource(.appleMusic)
            if !current { Task { await deck.music.play(song) } }
            dismiss()
        } label: {
            HStack(spacing: 12) {
                if let image = song.artwork?.image(at: CGSize(width: 52, height: 52)) {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    Image(systemName: "music.note").frame(width: 48, height: 48).background(InstrumentTheme.panel, in: RoundedRectangle(cornerRadius: 7))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title ?? "Untitled song").foregroundStyle(.primary).lineLimit(1)
                    Text(song.artist ?? "Unknown artist").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if current { Image(systemName: "waveform").foregroundStyle(InstrumentTheme.accents[0]) }
            }.padding(.vertical, 3)
        }
    }
}
