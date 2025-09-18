package com.example.indian_nagish

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.indian_nagish/remote_audio"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler {
            call, result ->
            if (call.method == "getRemoteAudio") {
                // TODO: Add your Agora remote audio processing here
                // For now, just return a test string
                val remoteAudioText = "Remote audio processed!"
                result.success(remoteAudioText)
            } else {
                result.notImplemented()
            }
        }
    }
}