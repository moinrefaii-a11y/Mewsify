package com.example.melody

import android.app.PictureInPictureParams
import android.os.Build
import android.util.Rational
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// audio_service requires the host Activity to extend AudioServiceActivity.
// On top of that we expose a `melody/pip` method channel so Flutter can
// request `enterPictureInPictureMode()` when the user backgrounds the
// app while video mode is on.
class MainActivity : AudioServiceActivity() {
    private val pipChannel = "melody/pip"
    private var pipEnabledFromFlutter = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pipChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setVideoMode" -> {
                        pipEnabledFromFlutter = call.argument<Boolean>("on") ?: false
                        result.success(true)
                    }
                    "isPipSupported" -> {
                        val supported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            packageManager.hasSystemFeature(
                                android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE
                            )
                        result.success(supported)
                    }
                    "enterPip" -> {
                        result.success(tryEnterPip())
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // Auto-PiP when user presses Home while video is playing.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (pipEnabledFromFlutter) tryEnterPip()
    }

    private fun tryEnterPip(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            enterPictureInPictureMode(
                PictureInPictureParams.Builder()
                    .setAspectRatio(Rational(16, 9))
                    .build()
            )
        } catch (_: Exception) {
            // PiP can fail if the activity isn't currently resumed; ignore.
            false
        }
    }
}
