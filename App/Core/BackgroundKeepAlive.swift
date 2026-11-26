import Foundation
import AVFoundation

/// Keeps the app running in the background while it has open positions, so the Live Activity stays live:
/// the app plays silence through an audio session that mixes with other audio (it does not interrupt music),
/// which iOS treats as background audio. Costs battery (network + a little CPU) — on/off in Settings.
@MainActor
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()

    private var player: AVAudioPlayer?
    private(set) var running = false
    private var observer: NSObjectProtocol?

    func start() {
        guard !running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let p = try AVAudioPlayer(data: Self.silence)
            p.numberOfLoops = -1
            p.volume = 0.01   // the data is silence anyway; a zero volume may let iOS treat the app as idle
            p.prepareToPlay()
            p.play()
            player = p
            running = true
            // A call or another app taking the audio exclusively pauses us: resume when it ends.
            observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                              object: nil, queue: .main) { note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                Task { @MainActor in
                    guard BackgroundKeepAlive.shared.running else { return }
                    try? AVAudioSession.sharedInstance().setActive(true)
                    BackgroundKeepAlive.shared.player?.play()
                }
            }
        } catch {
            stop()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if running { try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation]) }
        running = false
    }

    /// One second of 8 kHz mono 16-bit silence as a WAV file.
    private static let silence: Data = {
        let sampleRate: UInt32 = 8000, samples = 8000
        let dataSize = UInt32(samples * 2)
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }()
}
