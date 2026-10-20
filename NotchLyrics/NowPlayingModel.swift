//
//  NowPlayingModel.swift
//  NotchLyrics
//
//  One observable model for the current track. SwiftUI animates the same
//  panel between collapsed and expanded using this state.
//

import AppKit
import Combine
import SwiftUI

enum MusicPlayer: Equatable {
    case spotify
    case music
}

@MainActor
final class NowPlayingModel: ObservableObject {
    @Published var isExpanded = false
    @Published var hasTrack = false
    @Published var title = ""
    @Published var artist = ""
    @Published var isPlaying = false
    @Published var position: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var artwork: NSImage?
    @Published var player: MusicPlayer?
    @Published var notchSize = CGSize(width: 185, height: 32)

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    private var observers: [NSObjectProtocol] = []
    private var progressTimer: Timer?
    private var ticksSinceSync = 0
    private var artworkToken = 0
    private var loadedArtworkKey: String?
    private let scriptQueue = DispatchQueue(label: "notchlyrics.applescript", qos: .userInitiated)

    func start() {
        registerNotifications()
        refreshFromRunningPlayers()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickProgress()
            }
        }
        if let progressTimer {
            RunLoop.main.add(progressTimer, forMode: .common)
        }
    }

    deinit {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        progressTimer?.invalidate()
    }

    func playPause() {
        sendCommand("playpause")
    }

    func nextTrack() {
        sendCommand("next track")
    }

    func previousTrack() {
        sendCommand("previous track")
    }

    // MARK: - Notifications

    private func registerNotifications() {
        let center = DistributedNotificationCenter.default()
        let names: [(Notification.Name, MusicPlayer)] = [
            (Notification.Name("com.spotify.client.PlaybackStateChanged"), .spotify),
            (Notification.Name("com.apple.Music.playerInfo"), .music)
        ]

        for (name, player) in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.handlePlayerNotification(notification, player: player)
                }
            }
            observers.append(token)
        }
    }

    private func handlePlayerNotification(_ notification: Notification, player: MusicPlayer) {
        let info = notification.userInfo ?? [:]
        let state = stringValue(info["Player State"] ?? info["PlayerState"]).lowercased()

        if state.contains("stop") {
            if self.player == player {
                clearTrack()
            }
            return
        }

        let nextTitle = stringValue(info["Name"] ?? info["name"])
        let nextArtist = stringValue(info["Artist"] ?? info["artist"])
        let playing = state.contains("play") && !state.contains("pause")

        var nextDuration = seconds(from: info["Duration"] ?? info["Total Time"] ?? info["TotalTime"])
        var nextPosition = seconds(from: info["Playback Position"] ?? info["PlaybackPosition"])

        // Spotify duration in notifications is milliseconds; position is seconds.
        if player == .spotify, let raw = doubleValue(info["Duration"]), raw > 10_000 {
            nextDuration = raw / 1000
        }
        if player == .music, let raw = doubleValue(info["Total Time"] ?? info["TotalTime"]), raw > 10_000 {
            nextDuration = raw / 1000
        }

        applyTrack(
            player: player,
            title: nextTitle,
            artist: nextArtist,
            isPlaying: playing,
            position: nextPosition,
            duration: nextDuration
        )

        refreshDetails(for: player)
    }

    // MARK: - Track state

    private func applyTrack(
        player: MusicPlayer,
        title: String,
        artist: String,
        isPlaying: Bool,
        position: TimeInterval?,
        duration: TimeInterval?
    ) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty || !trimmedArtist.isEmpty else {
            if self.player == player {
                clearTrack()
            }
            return
        }

        let trackChanged = self.player != player || self.title != trimmedTitle || self.artist != trimmedArtist

        self.player = player
        hasTrack = true
        self.title = trimmedTitle.isEmpty ? "Unknown title" : trimmedTitle
        self.artist = trimmedArtist
        self.isPlaying = isPlaying
        if let duration, duration > 0 {
            self.duration = duration
        }
        if let position {
            self.position = min(max(position, 0), self.duration > 0 ? self.duration : position)
        }
        if trackChanged {
            artwork = nil
            loadedArtworkKey = nil
            loadArtwork(for: player, title: self.title, artist: self.artist)
        }
    }

    private func clearTrack() {
        hasTrack = false
        title = ""
        artist = ""
        isPlaying = false
        position = 0
        duration = 0
        artwork = nil
        player = nil
        loadedArtworkKey = nil
    }

    private func tickProgress() {
        guard hasTrack, isPlaying, duration > 0 else { return }
        position = min(position + 0.25, duration)
        ticksSinceSync += 1
        if ticksSinceSync >= 8 {
            ticksSinceSync = 0
            refreshDetails(for: player)
        }
    }

    // MARK: - AppleScript

    private func refreshFromRunningPlayers() {
        scriptQueue.async { [weak self] in
            let spotify = Self.snapshotScript(player: .spotify)
            let music = Self.snapshotScript(player: .music)
            let spotifySnapshot = Self.parseSnapshot(Self.runString(spotify), player: .spotify)
            let musicSnapshot = Self.parseSnapshot(Self.runString(music), player: .music)

            DispatchQueue.main.async {
                guard let self else { return }
                if let spotifySnapshot, spotifySnapshot.isPlaying {
                    self.applySnapshot(spotifySnapshot)
                } else if let musicSnapshot, musicSnapshot.isPlaying {
                    self.applySnapshot(musicSnapshot)
                } else if let spotifySnapshot {
                    self.applySnapshot(spotifySnapshot)
                } else if let musicSnapshot {
                    self.applySnapshot(musicSnapshot)
                } else {
                    self.clearTrack()
                }
            }
        }
    }

    private func refreshDetails(for player: MusicPlayer?) {
        guard let player else { return }
        scriptQueue.async { [weak self] in
            let snapshot = Self.parseSnapshot(Self.runString(Self.snapshotScript(player: player)), player: player)
            DispatchQueue.main.async {
                guard let self, let snapshot else { return }
                if snapshot.stopped {
                    if self.player == player {
                        self.clearTrack()
                    }
                    return
                }
                self.applySnapshot(snapshot)
            }
        }
    }

    private func applySnapshot(_ snapshot: PlayerSnapshot) {
        applyTrack(
            player: snapshot.player,
            title: snapshot.title,
            artist: snapshot.artist,
            isPlaying: snapshot.isPlaying,
            position: snapshot.position,
            duration: snapshot.duration
        )
        if snapshot.player == .spotify, let url = snapshot.artworkURL {
            fetchSpotifyArtwork(from: url, key: snapshot.artworkKey)
        } else if snapshot.player == .music {
            loadArtwork(for: .music, title: snapshot.title, artist: snapshot.artist)
        }
    }

    private func loadArtwork(for player: MusicPlayer, title: String, artist: String) {
        let key = "\(player)-\(title)-\(artist)"
        guard loadedArtworkKey != key else { return }
        artworkToken += 1
        let token = artworkToken

        switch player {
        case .spotify:
            scriptQueue.async { [weak self] in
                let urlString = Self.runString(Self.spotifyArtworkURLScript)?.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    guard let self, self.artworkToken == token, let urlString, let url = URL(string: urlString) else { return }
                    self.fetchSpotifyArtwork(from: url, key: key)
                }
            }
        case .music:
            scriptQueue.async { [weak self] in
                let image = Self.musicArtworkImage()
                DispatchQueue.main.async {
                    guard let self, self.artworkToken == token else { return }
                    self.artwork = image
                    self.loadedArtworkKey = key
                }
            }
        }
    }

    private func fetchSpotifyArtwork(from url: URL, key: String) {
        guard loadedArtworkKey != key else { return }
        artworkToken += 1
        let token = artworkToken
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let image = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                guard let self, self.artworkToken == token else { return }
                self.artwork = image
                self.loadedArtworkKey = key
            }
        }.resume()
    }

    private func sendCommand(_ command: String) {
        guard let player else { return }
        let appName = player == .spotify ? "Spotify" : "Music"
        let source = """
        if application "\(appName)" is running then
            tell application "\(appName)" to \(command)
        end if
        """
        scriptQueue.async { [weak self] in
            _ = Self.run(source)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self?.refreshDetails(for: player)
            }
        }
    }

    // MARK: - Scripts

    private struct PlayerSnapshot {
        var player: MusicPlayer
        var title: String
        var artist: String
        var isPlaying: Bool
        var position: TimeInterval
        var duration: TimeInterval
        var artworkURL: URL?
        var stopped: Bool { title.isEmpty && artist.isEmpty }

        var artworkKey: String { "\(player)-\(title)-\(artist)" }
    }

    private static func snapshotScript(player: MusicPlayer) -> String {
        let appName = player == .spotify ? "Spotify" : "Music"
        let artworkLine = player == .spotify ? "set art to artwork url of current track\n" : "set art to \"\"\n"
        return """
        if application "\(appName)" is running then
            tell application "\(appName)"
                if player state is stopped then return "stopped"
                set ps to player state as text
                set nm to name of current track
                set ar to artist of current track
                set dur to duration of current track
                set pos to player position
                \(artworkLine)
                return ps & tab & nm & tab & ar & tab & (dur as text) & tab & (pos as text) & tab & art
            end tell
        else
            return "not_running"
        end if
        """
    }

    private static let spotifyArtworkURLScript = """
    if application "Spotify" is running then
        tell application "Spotify"
            if player state is stopped then return ""
            return artwork url of current track
        end tell
    end if
    return ""
    """

    private static func parseSnapshot(_ raw: String?, player: MusicPlayer) -> PlayerSnapshot? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "not_running" || trimmed == "stopped" {
            return nil
        }
        let parts = trimmed.components(separatedBy: "\t")
        guard parts.count >= 5 else { return nil }
        let playing = parts[0].lowercased().contains("play") && !parts[0].lowercased().contains("pause")
        var duration = Double(parts[3].replacingOccurrences(of: ",", with: ".")) ?? 0
        let position = Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
        if player == .spotify, duration > 10_000 {
            duration /= 1000
        }
        let artworkURL = parts.count > 5 ? URL(string: parts[5]) : nil
        return PlayerSnapshot(
            player: player,
            title: parts[1],
            artist: parts[2],
            isPlaying: playing,
            position: position,
            duration: duration,
            artworkURL: artworkURL
        )
    }

    private static func musicArtworkImage() -> NSImage? {
        let source = """
        if application "Music" is running then
            tell application "Music"
                try
                    if player state is stopped then return
                    if (count of artworks of current track) is 0 then return
                    return raw data of artwork 1 of current track
                end try
            end tell
        end if
        """
        guard let descriptor = run(source) else { return nil }
        return image(from: descriptor)
    }

    @discardableResult
    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil { return nil }
        return result
    }

    private static func runString(_ source: String) -> String? {
        run(source)?.stringValue
    }

    private static func image(from descriptor: NSAppleEventDescriptor) -> NSImage? {
        if let data = descriptor.data, let image = NSImage(data: data) {
            return image
        }
        if descriptor.numberOfItems > 0 {
            for index in 1...descriptor.numberOfItems {
                if let child = descriptor.atIndex(index), let image = image(from: child) {
                    return image
                }
            }
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let value { return String(describing: value) }
        return ""
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func seconds(from value: Any?) -> TimeInterval? {
        guard let raw = doubleValue(value) else { return nil }
        return raw
    }
}
