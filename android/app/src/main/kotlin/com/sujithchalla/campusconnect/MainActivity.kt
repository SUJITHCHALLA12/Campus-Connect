package com.sujithchalla.campusconnect

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var wifiDirectHelper: WifiDirectHelper? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Raw Wi-Fi Direct fallback for fast file transfer (see
        // WifiDirectHelper.kt). The helper owns the MethodChannel
        // handler; MainActivity only wires it up and disposes it.
        // Guarded: Wi-Fi Direct is a fallback transport — a failure
        // here must never take the app down at launch. If setup
        // fails, the Dart side sees an unavailable channel and file
        // transfer falls back to BLE.
        try {
            val helper = WifiDirectHelper(this)
            val channel = MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                WifiDirectHelper.CHANNEL,
            )
            helper.bind(channel)
            channel.setMethodCallHandler(helper)
            wifiDirectHelper = helper
        } catch (e: Exception) {
            android.util.Log.e("CampusConnect", "Wi-Fi Direct setup failed", e)
            wifiDirectHelper = null
        }
    }

    override fun onDestroy() {
        wifiDirectHelper?.dispose()
        wifiDirectHelper = null
        super.onDestroy()
    }
}
