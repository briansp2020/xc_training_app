import BackgroundTasks
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
  static let syncTaskId = "com.github.codingwithwarren.xctraining.sync"

  // Keeps the headless engine alive while a background sync runs.
  private var backgroundEngine: FlutterEngine?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Handlers must be registered before the app finishes launching — iOS
    // launches us directly into background when the task fires.
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.syncTaskId, using: nil
    ) { task in
      // The launch handler runs on an arbitrary queue; FlutterEngine wants
      // the main thread.
      DispatchQueue.main.async {
        self.handleSyncTask(task as! BGAppRefreshTask)
      }
    }
    Self.scheduleSync()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  // Ask iOS for a background-refresh wake no sooner than an hour from now.
  // Called at launch, on backgrounding (SceneDelegate), and after every task
  // run, so a request is always pending. Actual timing is entirely up to iOS
  // (typically hours, tuned to usage patterns); a submit with the same id
  // replaces the pending request, so calling this repeatedly is safe.
  static func scheduleSync() {
    let request = BGAppRefreshTaskRequest(identifier: syncTaskId)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      // BGTaskScheduler.Error.unavailable in Simulator / when the user turned
      // Background App Refresh off. Nothing to do — foreground sync still works.
      NSLog("[bg-sync] could not schedule: \(error)")
    }
  }

  // Runs one headless Dart sync (backgroundSync in lib/background_sync.dart)
  // and completes the task when Dart reports back — or when iOS's ~30s budget
  // expires, whichever comes first.
  private func handleSyncTask(_ task: BGAppRefreshTask) {
    Self.scheduleSync() // keep the chain going

    guard backgroundEngine == nil else {
      // A sync is somehow still running — don't stack a second engine.
      task.setTaskCompleted(success: false)
      return
    }

    let engine = FlutterEngine(name: "background_sync")
    backgroundEngine = engine
    engine.run(
      withEntrypoint: "backgroundSync",
      libraryURI: "package:xctraining/background_sync.dart"
    )
    GeneratedPluginRegistrant.register(with: engine)

    var finished = false
    let finish: (Bool) -> Void = { success in
      DispatchQueue.main.async {
        guard !finished else { return }
        finished = true
        engine.destroyContext()
        self.backgroundEngine = nil
        task.setTaskCompleted(success: success)
      }
    }

    let channel = FlutterMethodChannel(
      name: "xctraining/background_sync",
      binaryMessenger: engine.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      if call.method == "done" {
        result(nil)
        finish((call.arguments as? Bool) ?? false)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    task.expirationHandler = { finish(false) }
  }
}
