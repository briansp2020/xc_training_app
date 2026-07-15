import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  // Scene-based apps don't get applicationDidEnterBackground — this is the
  // backgrounding hook. Refresh the pending background-sync request so one is
  // always queued when the user leaves the app.
  override func sceneDidEnterBackground(_ scene: UIScene) {
    super.sceneDidEnterBackground(scene)
    AppDelegate.scheduleSync()
  }
}
