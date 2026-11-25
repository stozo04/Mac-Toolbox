import AVFoundation
import Foundation

/// One player per copy on the comparison screen, all on one timeline. Either the selected copy plays on its own, or
/// every copy plays together on one clock with the sound of one. A shorter copy holds its last frame.
@MainActor
@Observable
final class VaultSyncedPlayback {
    private(set) var players: [AVPlayer] = []
    private(set) var isPlaying = false
    /// The copy playing on its own, or nil when all play together.
    private(set) var solo: Int?
    private(set) var length: Double = 0
    private(set) var position: Double = 0
    var soundFrom = 0 {
        didSet { applySound() }
    }

    @ObservationIgnored private var timeObserver: (player: AVPlayer, token: Any)?
    @ObservationIgnored private var lengths: [Double] = []
    @ObservationIgnored private var loads = 0

    /// Time for every player to get its first frames ready, so they all start on the same host clock tick.
    private static let startDelay = CMTime(seconds: 0.3, preferredTimescale: 600)
    private static let tick = CMTime(seconds: 0.1, preferredTimescale: 600)
    /// Closer than this to a copy's end counts as having reached it.
    private static let endSlack = 0.15

    func load(_ urls: [URL]) {
        release()
        let load = loads
        players = urls.map { url in
            let player = AVPlayer(url: url)
            player.automaticallyWaitsToMinimizeStalling = false
            player.actionAtItemEnd = .pause
            return player
        }
        soundFrom = 0
        applySound()
        Task {
            var found: [Double] = []
            for player in players {
                let seconds = (try? await player.currentItem?.asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
                found.append(seconds.isFinite ? seconds : 0)
            }
            guard load == loads else { return }
            lengths = found
            length = found.max() ?? 0
        }
    }

    /// Plays or pauses the copy at `index` on its own. While all play together, it switches to that copy alone.
    func togglePlay(only index: Int) {
        if isPlaying && solo != nil { pause() } else { Task { await play(only: index) } }
    }

    /// Plays or pauses every copy together. While one plays alone, it switches to all of them.
    func togglePlayAll() {
        if isPlaying && solo == nil { pause() } else { Task { await play(only: nil) } }
    }

    /// While one copy plays on its own, selecting another carries on with that one from the same moment.
    func follow(_ index: Int) {
        guard isPlaying, solo != nil, solo != index else { return }
        Task { await play(only: index) }
    }

    func play(only index: Int?) async {
        guard !players.isEmpty else { return }
        let load = loads
        stop()
        if position >= length - Self.endSlack { position = 0 }
        await syncToPosition()
        guard load == loads else { return }
        solo = index
        let chosen = index.flatMap { players.indices.contains($0) ? [$0] : nil } ?? Array(players.indices)
        if let index { soundFrom = index } else { applySound() }
        let watched = chosen.max { (lengths.dropFirst($0).first ?? 0) < (lengths.dropFirst($1).first ?? 0) } ?? 0
        observe(watched)
        if chosen.count == 1 {
            players[watched].play()
        } else {
            let start = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), Self.startDelay)
            for player in chosen.map({ players[$0] }) {
                if player.currentItem?.status == .readyToPlay {
                    player.setRate(1, time: .invalid, atHostTime: start)
                } else {
                    player.play()
                }
            }
        }
        isPlaying = true
    }

    /// Every copy stops and lines up at the same moment, so the next play starts them together.
    func pause() {
        stop()
        Task { await syncToPosition() }
    }

    func seek(to seconds: Double) async {
        let wasPlaying = isPlaying
        stop()
        position = seconds
        await syncToPosition()
        if wasPlaying { await play(only: solo) }
    }

    func release() {
        loads += 1
        if let timeObserver { timeObserver.player.removeTimeObserver(timeObserver.token) }
        timeObserver = nil
        for player in players {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        players = []
        lengths = []
        isPlaying = false
        solo = nil
        length = 0
        position = 0
    }

    private func stop() {
        players.forEach { $0.pause() }
        isPlaying = false
    }

    private func syncToPosition() async {
        let time = CMTime(seconds: position, preferredTimescale: 600)
        for player in players {
            await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func applySound() {
        for (index, player) in players.enumerated() { player.isMuted = index != soundFrom }
    }

    /// Follows the copy that plays longest: the timeline moves with it, and playback is over when it reaches its end.
    private func observe(_ index: Int) {
        let player = players[index]
        if let timeObserver {
            guard timeObserver.player !== player else { return }
            timeObserver.player.removeTimeObserver(timeObserver.token)
        }
        let token = player.addPeriodicTimeObserver(forInterval: Self.tick, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                let seconds = CMTimeGetSeconds(time)
                self.position = seconds
                let end = self.lengths.dropFirst(index).first ?? self.length
                if end > 0, seconds >= end - Self.endSlack { self.stop() }
            }
        }
        timeObserver = (player, token)
    }
}
