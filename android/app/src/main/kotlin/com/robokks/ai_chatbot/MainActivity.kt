package com.robokks.ai_chatbot

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : FlutterActivity() {
    private var permissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "chatbot/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "battery" -> {
                    val bm = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                    result.success(
                        mapOf(
                            "level" to bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY),
                            "charging" to bm.isCharging,
                        ),
                    )
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "chatbot/termux").setMethodCallHandler { call, result ->
            when (call.method) {
                "isInstalled" -> result.success(isTermuxInstalled())
                "hasPermission" -> result.success(hasRunCommandPermission())
                "requestPermission" -> {
                    if (hasRunCommandPermission()) {
                        result.success(true)
                    } else {
                        permissionResult = result
                        requestPermissions(arrayOf(Termux.PERMISSION), PERMISSION_REQUEST)
                    }
                }
                "run" -> runInTermux(
                    call.argument<String>("path") ?: "",
                    call.argument<List<String>>("args") ?: emptyList(),
                    call.argument<String>("workdir"),
                    result,
                )
                else -> result.notImplemented()
            }
        }
    }

    private fun isTermuxInstalled(): Boolean = try {
        packageManager.getPackageInfo(Termux.PACKAGE, 0)
        true
    } catch (e: PackageManager.NameNotFoundException) {
        false
    }

    private fun hasRunCommandPermission(): Boolean =
        checkSelfPermission(Termux.PERMISSION) == PackageManager.PERMISSION_GRANTED

    /** Sends the command to Termux's RunCommandService; the result arrives
     *  in [TermuxResultReceiver] through a PendingIntent. */
    private fun runInTermux(path: String, args: List<String>, workdir: String?, result: MethodChannel.Result) {
        if (!isTermuxInstalled()) return result.error("not_installed", "Termux is not installed", null)
        if (!hasRunCommandPermission()) return result.error("no_permission", "Permission not granted", null)

        val id = nextId.incrementAndGet()
        TermuxResultReceiver.pending[id] = { data -> runOnUiThread { result.success(data) } }

        val callback = Intent(this, TermuxResultReceiver::class.java).putExtra(TermuxResultReceiver.EXTRA_ID, id)
        var flags = PendingIntent.FLAG_ONE_SHOT
        // Termux fills in the result extras, so the PendingIntent must be mutable.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) flags = flags or PendingIntent.FLAG_MUTABLE
        val pending = PendingIntent.getBroadcast(this, id, callback, flags)

        val intent = Intent().apply {
            setClassName(Termux.PACKAGE, "com.termux.app.RunCommandService")
            action = "com.termux.RUN_COMMAND"
            putExtra("com.termux.RUN_COMMAND_PATH", path)
            putExtra("com.termux.RUN_COMMAND_ARGUMENTS", args.toTypedArray())
            if (!workdir.isNullOrEmpty()) putExtra("com.termux.RUN_COMMAND_WORKDIR", workdir)
            putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
            putExtra("com.termux.RUN_COMMAND_PENDING_INTENT", pending)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
        } catch (e: Exception) {
            TermuxResultReceiver.pending.remove(id)
            result.error("start_failed", e.message ?: "Could not start Termux", null)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQUEST) {
            permissionResult?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
            permissionResult = null
        }
    }

    companion object {
        private const val PERMISSION_REQUEST = 4242
        private val nextId = AtomicInteger(1000)
    }
}

object Termux {
    const val PACKAGE = "com.termux"
    const val PERMISSION = "com.termux.permission.RUN_COMMAND"
}
