import AVFoundation
import CoreLocation

/// iOS stops simulating as soon as Waypoint's connection closes, and it
/// suspends apps in the background. While a location is active we keep the
/// app running with background location updates plus silent audio.
final class KeepAlive: NSObject, CLLocationManagerDelegate {
    static let shared = KeepAlive()

    private let manager = CLLocationManager()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var users = 0
    private var audioReady = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.pausesLocationUpdatesAutomatically = false
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
    }

    func requestPermission() {
        if manager.authorizationStatus == .notDetermined || manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
    }

    func acquire() {
        users += 1
        if users == 1 { start() }
    }

    func release() {
        users = max(users - 1, 0)
        if users == 0 { stop() }
    }

    private func start() {
        requestPermission()
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.startUpdatingLocation()
        }
        startAudio()
    }

    private func stop() {
        manager.stopUpdatingLocation()
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            if !audioReady {
                let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                engine.mainMixerNode.outputVolume = 0
                audioReady = true
            }
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
            buffer.frameLength = 44_100 // one second of silence, looped
            if !engine.isRunning { try engine.start() }
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            if !player.isPlaying { player.play() }
        } catch {
            NSLog("[Waypoint] Silent audio could not start: \(error)")
        }
    }

    @objc private func audioInterrupted(_ note: Notification) {
        guard users > 0,
              let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
        startAudio()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard users > 0 else { return }
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.allowsBackgroundLocationUpdates = true
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A fix is not needed; the updates only keep Waypoint running.
    }
}
