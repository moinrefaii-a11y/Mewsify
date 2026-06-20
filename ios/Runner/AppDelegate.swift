import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Configure the audio session to keep playback alive in the background
    // and route through the device's media controls. just_audio normally
    // does this itself, but setting it here guarantees behavior on cold start.
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      print("AVAudioSession setup failed: \(error)")
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
