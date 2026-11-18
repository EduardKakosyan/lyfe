import AVFoundation
import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// What the owner hears and feels during a session, eyes closed.
@MainActor
public protocol BreathCues: AnyObject {
    /// The session started, or the app came back to one in progress. The
    /// run fixes when every round begins, so every cue can be lined up now.
    func begin(_ run: BreathRun, now: Date)
    /// A tap ended a hold.
    func holdEnded()
    /// The hold in progress just passed last session's.
    func beatLast()
    /// The session is over. `completed` is false when it was stopped early
    /// with nothing recorded.
    func end(completed: Bool)
}

/// No sound, no vibration: for tests and previews.
public final class SilentCues: BreathCues {
    public init() {}
    public func begin(_ run: BreathRun, now: Date) {}
    public func holdEnded() {}
    public func beatLast() {}
    public func end(completed: Bool) {}
}

/// When each cue of a session falls, worked out from the run alone.
enum CuePlan {
    enum Sound: Equatable {
        /// Ten seconds before a hold.
        case warning
        /// Three, two and one second before a hold.
        case tick
        /// A round begins: hold now.
        case hold
    }

    /// Every cue still to come after `now`, in time order.
    static func cues(for run: BreathRun, after now: Date) -> [(at: Date, sound: Sound)] {
        guard !run.isFinished else { return [] }
        var cues: [(at: Date, sound: Sound)] = []
        for round in 1...max(run.table.rounds, 1) {
            let start = run.roundStart(round)
            // The first round follows a ten-second lead-in, which is its warning.
            if round > 1, run.table.roundS > 20 {
                cues.append((start.addingTimeInterval(-10), .warning))
            }
            for seconds in [3.0, 2.0, 1.0] {
                cues.append((start.addingTimeInterval(-seconds), .tick))
            }
            cues.append((start, .hold))
        }
        return cues.filter { $0.at > now }
    }
}

/// Tones through the speaker or headphones, and a tap of the phone's motor.
///
/// Every tone of the session is handed to the audio system when the session
/// starts, timed against the clock. The audio keeps playing with the screen
/// locked, and keeps the app running so the rounds carry on. It plays over
/// other audio without stopping it, and with the silent switch on.
public final class ToneCues: BreathCues {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var run: BreathRun?
    private var observers: [NSObjectProtocol] = []
    private var shutdown: Task<Void, Never>?

    public init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    public func begin(_ run: BreathRun, now: Date) {
        self.run = run
        shutdown?.cancel()
        observe()
        schedule(from: now)
    }

    public func holdEnded() {
        impact(.rigid)
    }

    public func beatLast() {
        notify(.success)
    }

    public func end(completed: Bool) {
        run = nil
        player.stop()
        guard completed, engine.isRunning else {
            stopEngine()
            return
        }
        // Three rising notes, then let the audio go.
        var at = 0.05
        for frequency in [660.0, 880.0, 1320.0] {
            play(tone(frequency, seconds: 0.22), in: at)
            at += 0.24
        }
        player.play()
        notify(.success)
        shutdown = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.stopEngine()
        }
    }

    // MARK: Scheduling

    /// Starts the audio and lines up every cue still to come.
    private func schedule(from now: Date) {
        guard let run else { return }
        activateSession()
        player.stop()
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                print("lyfe: the session will run without sound: \(error.localizedDescription)")
                return
            }
        }
        for cue in CuePlan.cues(for: run, after: now) {
            let buffer =
                switch cue.sound {
                case .warning: tone(520, seconds: 0.12, gain: 0.5)
                case .tick: tone(880, seconds: 0.07, gain: 0.6)
                case .hold: tone(1320, seconds: 0.55)
                }
            play(buffer, in: cue.at.timeIntervalSince(now))
        }
        player.play()
    }

    private func play(_ buffer: AVAudioPCMBuffer, in seconds: TimeInterval) {
        let host = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: max(0, seconds))
        player.scheduleBuffer(buffer, at: AVAudioTime(hostTime: host), options: [], completionHandler: nil)
    }

    /// A sine tone with soft edges, so it does not click.
    private func tone(_ frequency: Double, seconds: Double, gain: Float = 0.8) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        let fade = min(Double(frames) / 2, format.sampleRate * 0.012)
        for frame in 0..<Int(frames) {
            let edge = min(1, Double(frame) / fade, Double(Int(frames) - frame) / fade)
            let wave = sin(2 * Double.pi * frequency * Double(frame) / format.sampleRate)
            samples[frame] = Float(wave * edge) * gain
        }
        return buffer
    }

    // MARK: The audio system

    private func activateSession() {
        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
        #endif
    }

    private func stopEngine() {
        player.stop()
        engine.stop()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    /// A phone call or unplugged headphones stop the audio; line the rest
    /// of the session up again when it can play.
    private func observe() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let again: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.schedule(from: Date()) }
        }
        observers.append(
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main, using: again))
        #if os(iOS)
            observers.append(
                center.addObserver(
                    forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
                ) { [weak self] notification in
                    let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                    guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
                    Task { @MainActor in self?.schedule(from: Date()) }
                })
        #endif
    }

    // MARK: Vibration

    #if canImport(UIKit) && os(iOS)
        private func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
            UIImpactFeedbackGenerator(style: style).impactOccurred()
        }

        private func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
            UINotificationFeedbackGenerator().notificationOccurred(type)
        }
    #else
        private enum Style { case rigid }
        private enum Kind { case success }
        private func impact(_ style: Style) {}
        private func notify(_ type: Kind) {}
    #endif
}
