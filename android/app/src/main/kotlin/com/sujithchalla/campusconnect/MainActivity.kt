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
        val helper = WifiDirectHelper(this)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WifiDirectHelper.CHANNEL,
        )
        helper.bind(channel)
        channel.setMethodCallHandler(helper)
        wifiDirectHelper = helper
    }

    override fun onDestroy() {
        wifiDirectHelper?.dispose()
        wifiDirectHelper = null
        super.onDestroy()
    }
}
