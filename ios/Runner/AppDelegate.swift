import BackgroundTasks
import Flutter
import HealthKit
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
  static let syncTaskId = "com.github.codingwithwarren.xctraining.sync"

  private let healthStore = HKHealthStore()

  // Keeps the headless engine alive while a background sync runs.
  private var backgroundEngine: FlutterEngine?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Handlers must be registered before the app finishes launching — iOS
    // launches us directly into background when a task or HealthKit delivery
    // fires.
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
    setUpHealthKitBackgroundDelivery()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  // MARK: - Periodic wake (BGAppRefreshTask)

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

  private func handleSyncTask(_ task: BGAppRefreshTask) {
    Self.scheduleSync() // keep the chain going
    let forceFinish = runBackgroundSync(trigger: "bg-app-refresh") { success in
      task.setTaskCompleted(success: success)
    }
    task.expirationHandler = { forceFinish() }
  }

  // MARK: - Immediate wake on new workouts (HealthKit background delivery)

  // HealthKit wakes the app (via the healthkit.background-delivery
  // entitlement) whenever a new workout is saved — the "run ended → data on
  // the server minutes later" path. The observer query must be re-registered
  // on every launch; the update handler's completion callback must always be
  // called or HealthKit throttles future deliveries.
  private func setUpHealthKitBackgroundDelivery() {
    guard HKHealthStore.isHealthDataAvailable() else { return }
    let workoutType = HKObjectType.workoutType()

    let query = HKObserverQuery(sampleType: workoutType, predicate: nil) {
      _, completionHandler, error in
      guard error == nil else {
        NSLog("[bg-sync] workout observer error: \(String(describing: error))")
        completionHandler()
        return
      }
      DispatchQueue.main.async {
        let forceFinish = self.runBackgroundSync(trigger: "healthkit") { _ in
          completionHandler()
        }
        // HealthKit gives no expiration handler — enforce our own budget so
        // the completion callback always fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { forceFinish() }
      }
    }
    healthStore.execute(query)

    healthStore.enableBackgroundDelivery(for: workoutType, frequency: .immediate) {
      ok, error in
      if !ok {
        NSLog(
          "[bg-sync] enableBackgroundDelivery failed: \(String(describing: error))")
      }
    }
  }

  // MARK: - Shared headless sync runner

  // Runs one headless Dart sync (backgroundSync in lib/background_sync.dart)
  // and calls [onFinish] exactly once — when Dart reports back, or when the
  // returned force-finish closure is invoked (task expiration / watchdog),
  // whichever comes first. Main thread only.
  private func runBackgroundSync(
    trigger: String, onFinish: @escaping (Bool) -> Void
  ) -> () -> Void {
    guard backgroundEngine == nil else {
      // A sync is already running — don't stack a second engine. The running
      // sync covers this trigger's data anyway.
      onFinish(false)
      return {}
    }

    let engine = FlutterEngine(name: "background_sync")
    backgroundEngine = engine
    engine.run(
      withEntrypoint: "backgroundSync",
      libraryURI: "package:xctraining/background_sync.dart",
      initialRoute: nil,
      entrypointArgs: [trigger]
    )
    GeneratedPluginRegistrant.register(with: engine)

    var finished = false
    let finish: (Bool) -> Void = { success in
      DispatchQueue.main.async {
        guard !finished else { return }
        finished = true
        engine.destroyContext()
        self.backgroundEngine = nil
        onFinish(success)
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
    return { finish(false) }
  }
}
