package com.robokks.ai_chatbot

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import java.util.concurrent.ConcurrentHashMap

/** Receives the result of a command run by Termux (stdout, stderr, exit code). */
class TermuxResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getIntExtra(EXTRA_ID, -1)
        val callback = pending.remove(id) ?: return
        val bundle = intent.getBundleExtra("result")
        callback(
            mapOf(
                "stdout" to (bundle?.getString("stdout") ?: ""),
                "stderr" to (bundle?.getString("stderr") ?: ""),
                "exitCode" to (bundle?.getInt("exitCode", -1) ?: -1),
                "err" to (bundle?.getInt("err", 0) ?: 0),
                "errmsg" to (bundle?.getString("errmsg") ?: ""),
            ),
        )
    }

    companion object {
        const val EXTRA_ID = "execution_id"
        val pending = ConcurrentHashMap<Int, (Map<String, Any>) -> Unit>()
    }
}
