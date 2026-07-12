package com.github.codingwithwarren.xctraining

import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.contracts.ExerciseRouteRequestContract
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    // Health Connect grants route access only through its own dialogs, and the
    // health plugin never asks for it (it maps a WORKOUT_ROUTE read to plain
    // READ_EXERCISE), so we fire the two consent flows ourselves:
    //  - requestRoutesPermission: blanket "Exercise routes" permission
    //    (READ_EXERCISE_ROUTES, Android 15+).
    //  - requestRouteConsent: per-route consent dialog (Android 14+); its
    //    "Allow all" option unlocks every route going forward.

    private var pendingPermission: MethodChannel.Result? = null
    private var pendingConsent: MethodChannel.Result? = null

    private val routesPermission = "android.permission.health.READ_EXERCISE_ROUTES"

    private val permissionLauncher = registerForActivityResult(
        PermissionController.createRequestPermissionResultContract()
    ) { granted ->
        pendingPermission?.success(granted.contains(routesPermission))
        pendingPermission = null
    }

    private val consentLauncher = registerForActivityResult(
        ExerciseRouteRequestContract()
    ) { route ->
        pendingConsent?.success(route != null)
        pendingConsent = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "xctraining/route_access")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestRoutesPermission" -> {
                        try {
                            pendingPermission = result
                            permissionLauncher.launch(setOf(routesPermission))
                        } catch (e: Exception) {
                            pendingPermission = null
                            result.error("launch-failed", e.message, null)
                        }
                    }
                    "requestRouteConsent" -> {
                        val uuid = call.argument<String>("sessionUuid")
                        if (uuid == null) {
                            result.error("bad-args", "sessionUuid required", null)
                        } else {
                            try {
                                pendingConsent = result
                                consentLauncher.launch(uuid)
                            } catch (e: Exception) {
                                pendingConsent = null
                                result.error("launch-failed", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
