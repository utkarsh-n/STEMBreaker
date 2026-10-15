import SwiftUI
import UniformTypeIdentifiers
import StemCore

struct InstrumentView: View {
    @Bindable var deck: DeckStore
    @State private var showingImporter = false
    @State private var importingFourStems = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 12) {
                    header
                    sourceSwitch
                    ScopeView(deck: deck)
                        .frame(height: deck.source == .deck ? 276 : 304)
                    trackInfo
                    TransportView(deck: deck)
                    if deck.source == .deck {
                        StemMixerView(engine: deck.engine)
                        provenance
                    } else { applePanel }
                }
                .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 22)
            }
            .scrollIndicators(.hidden)
            .background(InstrumentTheme.background)
            .safeAreaInset(edge: .bottom) { dock }
            .overlay { if deck.busy { processing } }
        }
        .foregroundStyle(InstrumentTheme.ink)
        .sheet(item: $deck.sheet) { destination in
            switch destination {
            case .library: MusicLibraryView(deck: deck)
            case .guide: GuideView()
            case .importOptions: importOptions
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio], allowsMultipleSelection: importingFourStems) { result in
            switch result {
            case .success(let urls): deck.startImport(urls, fourStems: importingFourStems)
            case .failure(let error): deck.message = error.localizedDescription
            }
        }
        .alert("STEM breaker", isPresented: Binding(get: { deck.message != nil }, set: { if !$0 { deck.message = nil } })) {
            Button("OK") { deck.message = nil }
        } message: { Text(deck.message ?? "") }
        .onChange(of: scenePhase) { _, phase in
            deck.setVisualizationActive(phase == .active)
            if phase == .active { deck.music.refresh(); deck.music.startObserving() }
            if phase == .background { deck.microphone.stop(); deck.music.stopObserving() }
        }
        .onChange(of: deck.engine.errorMessage) { _, error in if let error { deck.message = error } }
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("STEM").font(.system(size: 31, weight: .black, design: .rounded)).tracking(-1.5)
                Text("breaker").font(.system(size: 25, weight: .light)).tracking(-1.2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                TechnicalLabel(text: "POCKET INSTRUMENT")
                TechnicalLabel(text: "01 / FOUR CHANNEL", color: InstrumentTheme.ink)
            }.accessibilityHidden(true)
        }
    }

    private var sourceSwitch: some View {
        HStack(spacing: 4) {
            ForEach(AudioSource.allCases) { source in
                Button { deck.changeSource(source) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: source == .deck ? "slider.vertical.3" : "music.note")
                        Text(source.rawValue).font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(deck.source == source ? InstrumentTheme.ink : .clear, in: Capsule())
                    .foregroundStyle(deck.source == source ? InstrumentTheme.background : InstrumentTheme.quiet)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(deck.source == source ? .isSelected : [])
                .accessibilityIdentifier(source == .deck ? "source-deck" : "source-apple")
            }
        }
        .padding(4).background(InstrumentTheme.panel, in: Capsule())
    }

    private var trackInfo: some View {
        HStack(spacing: 12) {
            if deck.source == .appleMusic, let artwork = deck.music.artwork {
                Image(uiImage: artwork).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(deck.title).font(.system(size: 21, weight: .semibold)).lineLimit(1).accessibilityIdentifier("track-title")
                if deck.source == .appleMusic { Text(deck.subtitle).font(.caption).foregroundStyle(InstrumentTheme.quiet).lineLimit(1) }
                else { TechnicalLabel(text: "FOUR CHANNEL REMIX SESSION") }
            }
            Spacer(minLength: 0)
            Text("\(timecode(deck.duration))").font(.system(size: 11, design: .monospaced)).foregroundStyle(InstrumentTheme.quiet)
        }
    }

    private var provenance: some View {
        Button { deck.sheet = .guide } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                Text(deck.engine.session?.provenance ?? "Four independent demo tracks")
                    .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.foregroundStyle(InstrumentTheme.quiet)
        }.buttonStyle(.plain).accessibilityIdentifier("session-provenance")
    }

    private var applePanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                TechnicalLabel(text: "LISTEN TO YOUR OUTPUT", color: InstrumentTheme.ink)
                Spacer()
                Image(systemName: "waveform").foregroundStyle(InstrumentTheme.accents[0])
            }
            Text(deck.outputAudio.isListening ? "Your audio, straight to the scope." : deck.microphone.isListening ? "Visualizing the room around your iPhone." : "Headphones on. See the sound.")
                .font(.system(size: 18, weight: .medium))
            Text(deck.outputAudio.isSupported ? "Listen to live device audio through Apple’s sharing picker. It uses no microphone and keeps your Bluetooth output route. Some apps or protected playback may not supply audio." : "Live output sharing is unavailable on this device. It requires iOS 27 and enabled system screen sharing. Song details and playback position still work. Imported audio is visualized directly, including with Bluetooth headphones.")
                .font(.system(size: 12)).foregroundStyle(InstrumentTheme.quiet).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("output-explanation")
            if #available(iOS 27, *) {
                Button { Task { await deck.toggleOutputAudio() } } label: {
                    Label(deck.outputAudio.isListening || deck.outputAudio.isStarting ? "Stop output listening" : "Listen to output", systemImage: deck.outputAudio.isListening ? "stop.circle" : "headphones")
                        .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).tint(InstrumentTheme.accents[0]).foregroundStyle(InstrumentTheme.background)
                    .accessibilityIdentifier("output-toggle")
                if deck.outputAudio.isStarting || deck.outputAudio.isListening || deck.outputAudio.errorMessage != nil {
                    Text(deck.outputAudio.status).font(.caption).foregroundStyle(InstrumentTheme.quiet)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("output-status")
                }
            }
            HStack {
                Button { Task { await deck.toggleMicrophone() } } label: {
                    Label(deck.microphone.isListening ? "Stop microphone" : "Use room microphone", systemImage: deck.microphone.isListening ? "mic.slash" : "mic")
                        .font(.system(size: 12, weight: .semibold)).frame(minHeight: 44)
                }.buttonStyle(.bordered).tint(InstrumentTheme.accents[0]).accessibilityIdentifier("mic-toggle")
                Spacer()
                Button("Library") { deck.sheet = .library }.font(.system(size: 13, weight: .semibold)).frame(minHeight: 44)
            }
            if deck.microphone.isListening {
                Text(deck.microphone.routeDescription).font(.caption).foregroundStyle(InstrumentTheme.quiet)
            }
            if let error = deck.outputAudio.errorMessage ?? deck.microphone.errorMessage ?? deck.music.errorMessage { Text(error).font(.caption).foregroundStyle(InstrumentTheme.accents[0]) }
            Divider().overlay(InstrumentTheme.quiet.opacity(0.2))
            Text("To remix this song, import an unprotected audio file or its original stems.").font(.system(size: 11)).foregroundStyle(InstrumentTheme.quiet)
        }.padding(18).background(InstrumentTheme.panel, in: RoundedRectangle(cornerRadius: 20))
    }

    private var dock: some View {
        HStack(spacing: 12) {
            Button { deck.sheet = .library } label: { Label("Library", systemImage: "music.note.list").frame(maxWidth: .infinity, minHeight: 46) }
                .accessibilityIdentifier("open-library")
            Button { deck.sheet = .importOptions } label: { Label("Import", systemImage: "arrow.down.doc").frame(maxWidth: .infinity, minHeight: 46) }
                .accessibilityIdentifier("open-import")
            Button { deck.sheet = .guide } label: { Image(systemName: "questionmark.circle").frame(width: 46, height: 46) }
                .accessibilityLabel("About this instrument").accessibilityIdentifier("open-guide")
        }
        .font(.system(size: 13, weight: .medium)).buttonStyle(.plain)
        .padding(.horizontal, 22).padding(.top, 9).padding(.bottom, 6)
        .background(InstrumentTheme.background.opacity(0.98))
        .overlay(alignment: .top) { Rectangle().fill(InstrumentTheme.quiet.opacity(0.2)).frame(height: 1) }
    }

    private var processing: some View {
        ZStack {
            InstrumentTheme.background.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView(value: deck.progress).tint(InstrumentTheme.accents[1]).frame(width: 210)
                Text(deck.progressLabel).font(.headline)
                Text("Audio stays on your iPhone.").font(.caption).foregroundStyle(InstrumentTheme.quiet)
                if deck.isSeparating { Button("Cancel") { deck.cancelImport() }.buttonStyle(.bordered).accessibilityIdentifier("cancel-import") }
            }.padding(24)
        }.accessibilityIdentifier("processing")
    }

    private var importOptions: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        importingFourStems = false; deck.sheet = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showingImporter = true }
                    } label: {
                        Label { VStack(alignment: .leading, spacing: 6) {
                            Text("Break an audio file").foregroundStyle(.primary)
                            Text("On-device AI vocals + estimated instrument layers. WAV, MP3, M4A and AIFF. Up to 3 minutes.").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6) } icon: { Image(systemName: "waveform.path") }
                    }.accessibilityIdentifier("import-mix")
                    Button {
                        importingFourStems = true; deck.sheet = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showingImporter = true }
                    } label: {
                        Label { VStack(alignment: .leading, spacing: 6) {
                            Text("Load four original stems").foregroundStyle(.primary)
                            Text("Select four aligned files named vocals, drums, bass and other. Up to 3 minutes.").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6) } icon: { Image(systemName: "square.stack.3d.up") }
                    }.accessibilityIdentifier("import-stems")
                } footer: { Text("Protected Apple Music downloads cannot be imported or separated.") }
                Section {
                    Button("Load original demo") { deck.sheet = nil; Task { await deck.loadDemo() } }.accessibilityIdentifier("load-demo")
                    Button { Task { await deck.export() } } label: { Label(deck.isExporting ? "Exporting…" : "Export remix deck as WAV", systemImage: "square.and.arrow.up") }
                        .disabled(deck.source != .deck || deck.engine.session == nil || deck.isExporting).accessibilityIdentifier("export-mix")
                    if let url = deck.exportURL { ShareLink("Share exported WAV", item: url).accessibilityIdentifier("share-mix") }
                }
            }
            .navigationTitle("Bring your sound").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { deck.sheet = nil } } }
        }.tint(InstrumentTheme.accents[1])
    }
}
