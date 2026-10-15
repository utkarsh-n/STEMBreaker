import Foundation
import MediaPlayer
import Observation
import UIKit

/// Reads and controls the Music app's authorized library and playback state.
/// Apple Music playback is not an audio-buffer source for the stem engine.
@MainActor
@Observable
final class AppleMusicBridge {
    var authorizationStatus = MPMediaLibrary.authorizationStatus()
    var songs: [MPMediaItem] = []
    var currentItem: MPMediaItem?
    var isPlaying = false
    var playbackTime = 0.0
    var duration = 0.0
    var errorMessage: String?
    var isLoading = false

    var artwork: UIImage? {
        currentItem?.artwork?.image(at: CGSize(width: 320, height: 320))
    }

    @ObservationIgnored private var player: MPMusicPlayerController?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var isObserving = false
    @ObservationIgnored private var playbackGeneration: UInt64 = 0

    isolated deinit {
        timer?.invalidate()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        if isObserving {
            player?.endGeneratingPlaybackNotifications()
            MPMediaLibrary.default().endGeneratingLibraryChangeNotifications()
        }
    }

    func connect() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        #if targetEnvironment(simulator)
        songs = []
        errorMessage = "Connect Apple Music on your iPhone. The simulator cannot access your music library or play Apple Music."
        return
        #else
        authorizationStatus = MPMediaLibrary.authorizationStatus()
        if authorizationStatus == .notDetermined {
            authorizationStatus = await withCheckedContinuation { continuation in
                MPMediaLibrary.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        }
        guard authorizationStatus == .authorized else {
            clearPlayback()
            errorMessage = authorizationMessage
            return
        }
        loadLibrary()
        startObserving()
        refresh()
        #endif
    }

    /// Refreshes transport and metadata without re-querying the entire library.
    func refresh() {
        authorizationStatus = MPMediaLibrary.authorizationStatus()
        guard authorizationStatus == .authorized else {
            stopObserving()
            songs = []
            clearPlayback()
            return
        }
        #if !targetEnvironment(simulator)
        let activePlayer = authorizedPlayer()
        currentItem = activePlayer.nowPlayingItem
        isPlaying = activePlayer.playbackState == .playing
        let itemDuration = currentItem?.playbackDuration ?? 0
        duration = itemDuration.isFinite ? max(0, itemDuration) : 0
        let time = activePlayer.currentPlaybackTime
        playbackTime = time.isFinite ? max(0, time) : 0
        #endif
    }

    func play(_ item: MPMediaItem) async {
        playbackGeneration &+= 1
        guard authorizationStatus == .authorized else {
            errorMessage = authorizationMessage
            return
        }
        #if targetEnvironment(simulator)
        errorMessage = "Apple Music playback is available on your iPhone."
        #else
        let requestGeneration = playbackGeneration
        let activePlayer = authorizedPlayer()
        errorMessage = nil
        let libraryItem = songs.first { $0.persistentID == item.persistentID }
        let queueItems = libraryItem == nil ? [item] : songs
        let descriptor = MPMusicPlayerMediaItemQueueDescriptor(
            itemCollection: MPMediaItemCollection(items: queueItems)
        )
        descriptor.startItem = libraryItem ?? item
        activePlayer.setQueue(with: descriptor)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                activePlayer.prepareToPlay { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            // A newer selection or transport action wins while preparation is
            // suspended. In particular, switching to the remix deck must not
            // let an old completion start Music over its local playback.
            guard requestGeneration == playbackGeneration, !Task.isCancelled else { return }
            // Permission may have changed while the player prepared the item.
            guard MPMediaLibrary.authorizationStatus() == .authorized else {
                refresh()
                errorMessage = authorizationMessage
                return
            }
            activePlayer.play()
            startObserving()
            refresh()
        } catch {
            guard requestGeneration == playbackGeneration, !Task.isCancelled else { return }
            errorMessage = "Music could not play this song. \(error.localizedDescription)"
            refresh()
        }
        #endif
    }

    func togglePlayback() {
        playbackGeneration &+= 1
        guard authorizationStatus == .authorized else {
            errorMessage = authorizationMessage
            return
        }
        #if !targetEnvironment(simulator)
        let activePlayer = authorizedPlayer()
        if activePlayer.playbackState == .playing {
            activePlayer.pause()
        } else if activePlayer.nowPlayingItem != nil {
            activePlayer.play()
        } else {
            errorMessage = "Choose a song from your library, or start one in Music."
        }
        refresh()
        #endif
    }

    func skipNext() {
        playbackGeneration &+= 1
        guard authorizationStatus == .authorized, let player else { return }
        player.skipToNextItem()
        refresh()
    }

    func pausePlayback() {
        playbackGeneration &+= 1
        guard authorizationStatus == .authorized, let player else { return }
        player.pause()
        refresh()
    }

    func skipPrevious() {
        playbackGeneration &+= 1
        guard authorizationStatus == .authorized, let player else { return }
        player.skipToPreviousItem()
        refresh()
    }

    func seek(to time: Double) {
        guard authorizationStatus == .authorized, let player, time.isFinite else { return }
        player.currentPlaybackTime = min(max(0, time), max(0, duration))
        refresh()
    }

    func startObserving() {
        guard authorizationStatus == .authorized, !isObserving else { return }
        #if !targetEnvironment(simulator)
        let activePlayer = authorizedPlayer()
        isObserving = true
        activePlayer.beginGeneratingPlaybackNotifications()
        MPMediaLibrary.default().beginGeneratingLibraryChangeNotifications()

        let center = NotificationCenter.default
        let playbackNames: [Notification.Name] = [
            .MPMusicPlayerControllerNowPlayingItemDidChange,
            .MPMusicPlayerControllerPlaybackStateDidChange
        ]
        for name in playbackNames {
            observers.append(center.addObserver(forName: name, object: activePlayer, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            })
        }
        observers.append(center.addObserver(forName: .MPMediaLibraryDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.loadLibrary()
                self?.refresh()
            }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        #endif
    }

    func stopObserving() {
        timer?.invalidate()
        timer = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        if isObserving {
            player?.endGeneratingPlaybackNotifications()
            MPMediaLibrary.default().endGeneratingLibraryChangeNotifications()
        }
        isObserving = false
    }

    private func authorizedPlayer() -> MPMusicPlayerController {
        if let player { return player }
        let systemPlayer = MPMusicPlayerController.systemMusicPlayer
        player = systemPlayer
        return systemPlayer
    }

    private func loadLibrary() {
        guard MPMediaLibrary.authorizationStatus() == .authorized else {
            songs = []
            return
        }
        #if !targetEnvironment(simulator)
        songs = (MPMediaQuery.songs().items ?? []).sorted {
            ($0.title ?? "").localizedStandardCompare($1.title ?? "") == .orderedAscending
        }
        if songs.isEmpty {
            errorMessage = "Your music library is empty. Add songs in Music, then return here. Songs already playing in Music can still appear on the deck."
        } else {
            errorMessage = nil
        }
        #endif
    }

    private func clearPlayback() {
        currentItem = nil
        isPlaying = false
        playbackTime = 0
        duration = 0
    }

    private var authorizationMessage: String {
        switch authorizationStatus {
        case .denied:
            "Music access is off. Enable Media & Apple Music for STEM Breaker in iPhone Settings."
        case .restricted:
            "Music access is restricted on this iPhone."
        case .notDetermined:
            "Connect Apple Music to browse your library and follow the song playing in Music."
        case .authorized:
            "Music access changed. Connect Apple Music again."
        @unknown default:
            "Music access is unavailable on this iPhone."
        }
    }
}
