import AudioToolbox
import AVFoundation
import Foundation

/// Asset-free, low-volume procedural UI sound engine for the circular HUD dial,
/// magnetic edge snapping, and parting-strip window insertion.
///
/// Every cue is synthesised into a small PCM buffer on demand and played through a single
/// shared `AVAudioPlayerNode`. Deliberately quiet, warm, and short — this is a peripheral
/// precision instrument sound, not an alert. If audio hardware is unavailable the engine
/// disables itself silently rather than throwing.
@MainActor
public final class HudSoundEngine {
    public static let shared = HudSoundEngine()

    public enum Cue: Hashable, Sendable {
        case hover
        case snap
        case grab
        case drop
        case bump
        /// Subtle magnetic lock chime when two window edges snap together.
        case magnetLock
        /// Soft crystalline shimmer when a new window parts the strip next to focus.
        case partingInsert
        /// Quiet wooden tick each time the endless strip loops back around on itself.
        case loopSeam
    }

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var isConfigured = false
    private var isDisabled = false
    private var lastPlayedAt: [Cue: CFTimeInterval] = [:]
    private var lastAnyCueAt: CFTimeInterval = 0
    /// Incremented on every cue; a delayed idle-shutdown checks it so a newer cue cancels it.
    private var idleGeneration: UInt64 = 0

    private let sampleRate: Double = 44_100
    private let globalMinimumInterval: CFTimeInterval = 0.018
    private let hoverMinimumInterval: CFTimeInterval = 0.055
    /// A lap can complete faster than the strip crosses the screen when the user flicks hard.
    /// Dropping the extra ticks keeps the cue a marker, not a rattle.
    private let loopSeamMinimumInterval: CFTimeInterval = 0.28
    /// Keep the output device alive while the user is interacting, then release it. Leaving
    /// AVAudioEngine running forever keeps the CoreAudio IO thread spinning at 15-20% CPU.
    private let idleShutdownDelay: UInt64 = 2_000_000_000

    private init() {}

    // MARK: - Public API

    /// Plays a cue if audio is enabled and the cue is not rate-limited away.
    public func play(_ cue: Cue) {
        let settings = SettingsStore.shared
        guard settings.hudSoundEnabled, !isDisabled else { return }
        let volume = min(1, max(0, settings.hudSoundVolume))
        guard volume > 0.001 else { return }

        let now = CACurrentMediaTime()
        if now - lastAnyCueAt < globalMinimumInterval { return }
        if cue == .hover, let last = lastPlayedAt[cue], now - last < hoverMinimumInterval { return }
        if cue == .loopSeam, let last = lastPlayedAt[cue], now - last < loopSeamMinimumInterval { return }

        configureIfNeeded()
        guard isConfigured, let player = self.player else { return }
        lastPlayedAt[cue] = now
        lastAnyCueAt = now

        guard let buffer = Self.buffer(for: cue, sampleRate: sampleRate) else { return }
        player.volume = Float(volume)
        if !player.isPlaying {
            player.play()
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        scheduleIdleShutdown()
    }

    /// Renders a cue to a PCM buffer without playing it (for unit test verification).
    func renderForTesting(_ cue: Cue, sampleRate: Double = 44_100) -> AVAudioPCMBuffer? {
        Self.buffer(for: cue, sampleRate: sampleRate)
    }

    /// Stops any tail and releases the audio device.
    public func shutdown() {
        idleGeneration &+= 1
        player?.stop()
        if let engine = self.engine {
            if engine.isRunning {
                engine.stop()
            }
            if let player = self.player, engine.attachedNodes.contains(player) {
                engine.detach(player)
            }
        }
        isConfigured = false
    }

    // MARK: - Engine Setup

    /// Stops the engine after a quiet period so an idle menu-bar app does not keep the
    /// CoreAudio IO thread running (measured at ~15-20% CPU before this was added).
    private func scheduleIdleShutdown() {
        idleGeneration &+= 1
        let generation = idleGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.idleShutdownDelay ?? 2_000_000_000)
            guard let self = self, self.idleGeneration == generation else { return }
            self.stopEngineForIdle()
        }
    }

    private func stopEngineForIdle() {
        guard isConfigured else { return }
        player?.stop()
        if let engine = self.engine, engine.isRunning {
            engine.stop()
        }
        // Keep the player attached and connected; the next cue only needs engine.start().
        isConfigured = false
    }

    private static var hasAudioHardware: Bool = {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Generator,
            componentSubType: kAudioUnitSubType_ScheduledSoundPlayer,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        var outDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        return AudioComponentFindNext(nil, &desc) != nil && AudioComponentFindNext(nil, &outDesc) != nil
    }()

    private func configureIfNeeded() {
        guard !isConfigured, !isDisabled else { return }
        guard Self.hasAudioHardware else {
            isDisabled = true
            return
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        guard let format else {
            isDisabled = true
            return
        }

        let eng: AVAudioEngine
        if let existing = self.engine {
            eng = existing
        } else {
            eng = AVAudioEngine()
            self.engine = eng
        }

        let node: AVAudioPlayerNode
        if let existingNode = self.player {
            node = existingNode
        } else {
            node = AVAudioPlayerNode()
            self.player = node
        }

        if !eng.attachedNodes.contains(node) {
            eng.attach(node)
            eng.connect(node, to: eng.mainMixerNode, format: format)
        }

        do {
            try eng.start()
        } catch {
            isDisabled = true
            return
        }

        isConfigured = true
    }

    // MARK: - Synthesis

    private static func buffer(for cue: Cue, sampleRate: Double) -> AVAudioPCMBuffer? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[cue] { return cached }
        guard let made = makeBuffer(for: cue, sampleRate: sampleRate) else { return nil }
        cache[cue] = made
        return made
    }

    private static func makeBuffer(for cue: Cue, sampleRate: Double) -> AVAudioPCMBuffer? {
        let spec = Spec.forCue(cue)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        let frameCount = AVAudioFrameCount(spec.duration * sampleRate)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount

        var phase = 0.0
        var noiseState: UInt64 = 12345
        var previous = 0.0

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let progress = t / spec.duration

            let frequency = spec.startFrequency + (spec.endFrequency - spec.startFrequency) * min(1, progress * spec.glideRate)
            let attack = min(1, t / max(0.0005, spec.attack))
            let decay = exp(-spec.decayRate * t)
            let envelope = attack * decay

            phase += 2 * Double.pi * frequency / sampleRate
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            var sample = sin(phase)

            if spec.harmonicMix > 0 {
                sample += spec.harmonicMix * sin(2 * phase)
            }

            if spec.noiseMix > 0 {
                noiseState = (noiseState &* 1_103_515_245 &+ 12_345) & 0x7FFF_FFFF
                let noise = (Double(noiseState) / Double(0x7FFF_FFFF)) - 0.5
                sample += spec.noiseMix * noise
            }

            if spec.lowpass > 0 {
                sample = previous + spec.lowpass * (sample - previous)
                previous = sample
            }

            channel[frame] = Float(sample * envelope * spec.amplitude)
        }

        let total = Int(frameCount)
        let fadeStart = max(0, total - 64)
        let tailValue = channel[fadeStart]
        let fadeLength = total - fadeStart
        for frame in fadeStart..<total {
            let k = Float(frame - fadeStart + 1) / Float(fadeLength + 1)
            channel[frame] = tailValue * (1 - k)
        }

        return buffer
    }

    private static let cacheLock = NSLock()
    private static var cache: [Cue: AVAudioPCMBuffer] = [:]

    private struct Spec {
        var duration: Double
        var startFrequency: Double
        var endFrequency: Double
        var glideRate: Double
        var decayRate: Double
        var attack: Double
        var amplitude: Double
        var harmonicMix: Double
        var noiseMix: Double
        var lowpass: Double

        static func forCue(_ cue: Cue) -> Spec {
            switch cue {
            case .hover:
                // Whisper-quiet precision watch tick
                return Spec(duration: 0.011, startFrequency: 2_100, endFrequency: 1_900, glideRate: 1,
                            decayRate: 360, attack: 0.0012, amplitude: 0.24,
                            harmonicMix: 0, noiseMix: 0, lowpass: 0.50)
            case .snap:
                // Soft mechanical detent click
                return Spec(duration: 0.028, startFrequency: 1_480, endFrequency: 1_080, glideRate: 1,
                            decayRate: 115, attack: 0.0016, amplitude: 0.50,
                            harmonicMix: 0.16, noiseMix: 0.22, lowpass: 0.58)
            case .grab:
                // Gentle upward lift cue when grabbing a window orb
                return Spec(duration: 0.070, startFrequency: 680, endFrequency: 1_420, glideRate: 1.5,
                            decayRate: 28, attack: 0.007, amplitude: 0.44,
                            harmonicMix: 0.12, noiseMix: 0.04, lowpass: 0.42)
            case .drop:
                // Warm seating confirmation when dropping a reordered window
                return Spec(duration: 0.105, startFrequency: 1_120, endFrequency: 780, glideRate: 2.2,
                            decayRate: 32, attack: 0.003, amplitude: 0.54,
                            harmonicMix: 0.20, noiseMix: 0.12, lowpass: 0.48)
            case .bump:
                // Soft low thud at strip boundary
                return Spec(duration: 0.120, startFrequency: 124, endFrequency: 92, glideRate: 1,
                            decayRate: 24, attack: 0.006, amplitude: 0.48,
                            harmonicMix: 0.30, noiseMix: 0, lowpass: 0.18)
            case .magnetLock:
                // Crisp magnetic lock harmonic click
                return Spec(duration: 0.065, startFrequency: 980, endFrequency: 1_460, glideRate: 2.0,
                            decayRate: 42, attack: 0.002, amplitude: 0.46,
                            harmonicMix: 0.28, noiseMix: 0.08, lowpass: 0.52)
            case .partingInsert:
                // Soft rising shimmer as neighboring columns part for a newly opened window
                return Spec(duration: 0.115, startFrequency: 580, endFrequency: 1_160, glideRate: 1.3,
                            decayRate: 22, attack: 0.008, amplitude: 0.40,
                            harmonicMix: 0.25, noiseMix: 0.02, lowpass: 0.40)
            case .loopSeam:
                // Warm wooden lap tick: the strip has come full circle and starts repeating
                return Spec(duration: 0.075, startFrequency: 520, endFrequency: 392, glideRate: 1.1,
                            decayRate: 46, attack: 0.0035, amplitude: 0.38,
                            harmonicMix: 0.20, noiseMix: 0.05, lowpass: 0.30)
            }
        }
    }
}
