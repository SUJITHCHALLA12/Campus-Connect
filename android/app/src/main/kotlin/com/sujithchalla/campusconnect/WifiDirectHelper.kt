package com.sujithchalla.campusconnect

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.wifi.WpsInfo
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/// Raw Wi-Fi Direct fallback for fast file transfer (see
/// lib/transfer/fast_file_transfer.dart). Used only when Nearby
/// Connections is unavailable or fails; BLE stays the last resort.
///
/// Protocol (one socket per file, sender → receiver):
/// 1. Handshake: one JSON line: {v, targetUserId, senderId,
///    senderName, transferId, fileName, mimeType, groupId, kind,
///    ts, fileSize}. The receiver closes the socket when
///    targetUserId != its own user id, so a sender probing
///    discovered devices lands on the intended peer.
/// 2. Exactly fileSize raw bytes.
/// 3. The receiver saves the file under cacheDir/wifidirect/ and
///    reports it to Dart via `onWifiDirectFile`; Dart moves it into
///    the app documents `received/` folder.
///
/// Peer matching: WifiP2pDevice has no app-level identity (only the
/// Android device name / MAC), so Dart tries discovered devices one
/// by one and the handshake's targetUserId does the matching.
///
/// Group-owner note: the sender requests the connection with
/// groupOwnerIntent = 0 (prefer the receiver as group owner), so the
/// sender can reach the receiver's server socket at the well-known
/// group-owner address (192.168.49.1). When the sender ends up as
/// group owner anyway, the receiver's IP is unknown — that candidate
/// is skipped and the caller falls back (BLE).
class WifiDirectHelper(
    private val context: Context,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.sujithchalla.campusconnect/wifi_direct"
        const val PORT = 8988
    }

    private var methodChannel: MethodChannel? = null
    private var ownUserId: String? = null

    private val manager: WifiP2pManager? =
        context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
    private val channel: WifiP2pManager.Channel? =
        manager?.initialize(context, context.mainLooper, null)

    private val peers = CopyOnWriteArrayList<WifiP2pDevice>()
    @Volatile
    private var peerLatch: CountDownLatch? = null
    private val receiverStarted = AtomicBoolean(false)
    private var serverSocket: ServerSocket? = null
    private var serverThread: Thread? = null
    private var broadcastReceiver: BroadcastReceiver? = null

    fun bind(channel: MethodChannel) {
        methodChannel = channel
    }

    fun dispose() {
        try {
            broadcastReceiver?.let { context.unregisterReceiver(it) }
        } catch (_: Exception) {
        }
        broadcastReceiver = null
        try {
            serverSocket?.close()
        } catch (_: Exception) {
        }
        serverSocket = null
        serverThread?.interrupt()
        serverThread = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startReceiver" -> {
                ownUserId = call.argument<String>("userId")
                startReceiver()
                result.success(true)
            }
            "stopReceiver" -> {
                dispose()
                result.success(true)
            }
            "discoverPeers" -> thread {
                result.success(discoverPeersBlocking())
            }
            "getPeers" -> result.success(peers.map { peerMap(it) })
            "connect" -> thread {
                val address = call.argument<String>("deviceAddress")
                if (address == null) {
                    result.error("bad_args", "deviceAddress missing", null)
                } else {
                    result.success(connectBlocking(address))
                }
            }
            "getConnectionInfo" -> thread {
                result.success(connectionInfoBlocking())
            }
            "sendFile" -> thread {
                result.success(sendFileBlocking(call))
            }
            "disconnect" -> thread {
                result.success(disconnectBlocking())
            }
            else -> result.notImplemented()
        }
    }

    private fun peerMap(device: WifiP2pDevice): Map<String, Any?> =
        mapOf(
            "deviceAddress" to device.deviceAddress,
            "deviceName" to device.deviceName,
        )

    // ─── Receiver ───────────────────────────────────────────────

    private fun startReceiver() {
        if (receiverStarted.getAndSet(true)) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> {
                        manager?.requestPeers(channel) { peerList ->
                            peers.clear()
                            peers.addAll(peerList.deviceList)
                            peerLatch?.countDown()
                        }
                    }
                    // Connection changes are polled by Dart via
                    // getConnectionInfo / connect — nothing to do here.
                }
            }
        }
        broadcastReceiver = receiver
        val filter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
        }
        // API 33+ requires an explicit exported flag for
        // registerReceiver; these are system broadcasts for this app
        // only, so the receiver is not exported.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(
                receiver,
                filter,
                Context.RECEIVER_NOT_EXPORTED,
            )
        } else {
            @Suppress("DEPRECATION")
            context.registerReceiver(receiver, filter)
        }

        serverThread = thread(name = "wifi-direct-server", isDaemon = true) {
            try {
                val server = ServerSocket(PORT)
                serverSocket = server
                while (!Thread.currentThread().isInterrupted) {
                    val socket = try {
                        server.accept()
                    } catch (_: Exception) {
                        break
                    }
                    thread(name = "wifi-direct-receive", isDaemon = true) {
                        handleIncoming(socket)
                    }
                }
            } catch (_: Exception) {
                // Port in use / Wi-Fi off — the Dart side treats the
                // whole Wi-Fi Direct path as unavailable.
            }
        }
    }

    private fun handleIncoming(socket: Socket) {
        try {
            val input = BufferedInputStream(socket.getInputStream())
            val handshakeLine = readLine(input, maxBytes = 8192) ?: return
            val meta = try {
                JSONObject(handshakeLine)
            } catch (_: Exception) {
                return
            }
            // Not for this phone — close without reading the file.
            if (meta.optString("targetUserId") != ownUserId) return
            val fileSize = meta.optLong("fileSize", -1)
            if (fileSize < 0) return
            val transferId = meta.optString("transferId")
            val rawName = meta.optString("fileName", "file")
            val safeName = rawName.replace(Regex("[\\\\/:*?\"<>|]"), "_")
            val dir = File(context.cacheDir, "wifidirect")
            if (!dir.exists()) dir.mkdirs()
            val outFile = File(dir, "${transferId}_$safeName")
            var received = 0L
            var lastProgressAt = 0L
            FileOutputStream(outFile).use { out ->
                val buffer = ByteArray(64 * 1024)
                while (received < fileSize) {
                    val want = minOf(buffer.size.toLong(), fileSize - received).toInt()
                    val read = input.read(buffer, 0, want)
                    if (read == -1) return // peer vanished mid-file
                    out.write(buffer, 0, read)
                    received += read
                    val now = System.currentTimeMillis()
                    if (now - lastProgressAt >= 200) {
                        lastProgressAt = now
                        methodChannel?.invokeMethod(
                            "onWifiDirectProgress",
                            mapOf(
                                "transferId" to transferId,
                                "bytesSent" to received,
                                "totalBytes" to fileSize,
                            ),
                        )
                    }
                }
            }
            methodChannel?.invokeMethod(
                "onWifiDirectFile",
                mapOf(
                    "path" to outFile.absolutePath,
                    "transferId" to transferId,
                    "fileName" to rawName,
                    "mimeType" to meta.optString("mimeType"),
                    "groupId" to if (meta.isNull("groupId")) null else meta.optString("groupId"),
                    "senderId" to meta.optString("senderId"),
                    "senderName" to meta.optString("senderName"),
                    "ts" to meta.optLong("ts"),
                    "kind" to meta.optString("kind", "file"),
                    "fileSize" to fileSize,
                ),
            )
        } catch (_: Exception) {
            // A failed receive must not kill the server thread.
        } finally {
            try {
                socket.close()
            } catch (_: Exception) {
            }
        }
    }

    /// Reads one '\n'-terminated line from [input] without
    /// over-reading: BufferedReader would buffer past the newline
    /// and swallow file bytes, so the line is read byte by byte
    /// from the same stream the file bytes follow on.
    private fun readLine(input: BufferedInputStream, maxBytes: Int): String? {
        val bytes = ByteArrayOutputStream()
        var count = 0
        while (count < maxBytes) {
            val b = input.read()
            if (b == -1) return null
            count++
            if (b == '\n'.code) break
            bytes.write(b)
        }
        return bytes.toString(Charsets.UTF_8.name())
    }

    // ─── Discovery / connect ────────────────────────────────────

    private fun discoverPeersBlocking(): List<Map<String, Any?>> {
        val mgr = manager
        val ch = channel
        if (mgr == null || ch == null) return emptyList()
        val latch = CountDownLatch(1)
        peerLatch = latch
        var requestOk = false
        mgr.discoverPeers(
            ch,
            object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    requestOk = true
                }

                override fun onFailure(reason: Int) {
                    latch.countDown()
                }
            },
        )
        // If the request itself failed, the latch is already down.
        // Otherwise the peers-changed broadcast counts it down when
        // the peer list arrives (up to 5 s).
        latch.await(5, TimeUnit.SECONDS)
        peerLatch = null
        if (!requestOk && peers.isEmpty()) return emptyList()
        return peers.map { peerMap(it) }
    }

    private fun connectBlocking(deviceAddress: String): Map<String, Any?> {
        val mgr = manager
        val ch = channel
        if (mgr == null || ch == null) {
            return mapOf("connected" to false)
        }
        val config = WifiP2pConfig().apply {
            this.deviceAddress = deviceAddress
            wps.setup = WpsInfo.PBC
            // Prefer the peer as group owner (see class doc).
            groupOwnerIntent = 0
        }
        val latch = CountDownLatch(1)
        var accepted = false
        mgr.connect(
            ch,
            config,
            object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    accepted = true
                    latch.countDown()
                }

                override fun onFailure(reason: Int) {
                    latch.countDown()
                }
            },
        )
        latch.await(15, TimeUnit.SECONDS)
        if (!accepted) return mapOf("connected" to false)
        // Wait for the group to actually form.
        val deadline = System.currentTimeMillis() + 15_000
        while (System.currentTimeMillis() < deadline) {
            val info = connectionInfoBlocking()
            if (info["groupFormed"] == true) return info
            Thread.sleep(500)
        }
        return mapOf("connected" to false)
    }

    private fun connectionInfoBlocking(): Map<String, Any?> {
        val mgr = manager
        val ch = channel
        if (mgr == null || ch == null) {
            return mapOf("groupFormed" to false)
        }
        val latch = CountDownLatch(1)
        var result: Map<String, Any?> = mapOf("groupFormed" to false)
        mgr.requestConnectionInfo(ch) { info: WifiP2pInfo? ->
            result = if (info?.groupFormed == true) {
                mapOf(
                    "groupFormed" to true,
                    "connected" to true,
                    "isGroupOwner" to info.isGroupOwner,
                    "groupOwnerAddress" to info.groupOwnerAddress?.hostAddress,
                )
            } else {
                mapOf("groupFormed" to false)
            }
            latch.countDown()
        }
        latch.await(5, TimeUnit.SECONDS)
        return result
    }

    private fun disconnectBlocking(): Boolean {
        val mgr = manager
        val ch = channel
        if (mgr == null || ch == null) return false
        val latch = CountDownLatch(1)
        var ok = false
        mgr.removeGroup(
            ch,
            object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    ok = true
                    latch.countDown()
                }

                override fun onFailure(reason: Int) {
                    latch.countDown()
                }
            },
        )
        latch.await(5, TimeUnit.SECONDS)
        return ok
    }

    // ─── Send ───────────────────────────────────────────────────

    private fun sendFileBlocking(call: MethodCall): Boolean {
        val hostIp = call.argument<String>("hostIp") ?: return false
        val filePath = call.argument<String>("filePath") ?: return false
        val file = File(filePath)
        if (!file.exists()) return false
        val meta = JSONObject().apply {
            put("v", 1)
            put("targetUserId", call.argument<String>("targetUserId"))
            put("senderId", call.argument<String>("senderId"))
            put("senderName", call.argument<String>("senderName"))
            put("transferId", call.argument<String>("transferId"))
            put("fileName", call.argument<String>("fileName"))
            put("mimeType", call.argument<String>("mimeType"))
            put("groupId", call.argument<String>("groupId"))
            put("kind", call.argument<String>("kind") ?: "file")
            put("ts", call.argument<Long>("ts") ?: System.currentTimeMillis())
            put("fileSize", file.length())
        }
        var socket: Socket? = null
        try {
            socket = Socket()
            socket.connect(InetSocketAddress(hostIp, PORT), 10_000)
            val out = BufferedOutputStream(socket.getOutputStream())
            out.write((meta.toString() + "\n").toByteArray(Charsets.UTF_8))
            out.flush()
            val total = file.length()
            var sent = 0L
            var lastProgressAt = 0L
            file.inputStream().use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = input.read(buffer)
                    if (read == -1) break
                    out.write(buffer, 0, read)
                    sent += read
                    val now = System.currentTimeMillis()
                    if (now - lastProgressAt >= 200) {
                        lastProgressAt = now
                        methodChannel?.invokeMethod(
                            "onWifiDirectProgress",
                            mapOf(
                                "transferId" to call.argument<String>("transferId"),
                                "bytesSent" to sent,
                                "totalBytes" to total,
                            ),
                        )
                    }
                }
            }
            out.flush()
            return sent == total
        } catch (_: Exception) {
            // Receiver rejected (closed socket), peer gone, timeout.
            return false
        } finally {
            try {
                socket?.close()
            } catch (_: Exception) {
            }
        }
    }
}
