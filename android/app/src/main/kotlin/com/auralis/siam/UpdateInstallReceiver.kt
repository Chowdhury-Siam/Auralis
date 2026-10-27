package com.auralis.siam

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.widget.Toast
import java.lang.ref.WeakReference

/** Explicit, non-exported destination for the system install session's mutable callback. */
class UpdateInstallReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION = "com.auralis.siam.UPDATE_RESULT"
        @Volatile internal var owner: WeakReference<AndroidUpdateInstaller>? = null
    }

    @Suppress("DEPRECATION")
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return
        val id = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        var status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        var message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            try {
                val confirmation = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                    ?: throw IllegalStateException("Missing install confirmation")
                context.startActivity(confirmation.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return
            } catch (_: Exception) {
                status = PackageInstaller.STATUS_FAILURE
                message = "Android could not open its update confirmation. Try installing again."
            }
        }
        val handled = owner?.get()?.installResult(id, status, message) == true
        if (!handled && status != PackageInstaller.STATUS_SUCCESS) {
            Toast.makeText(context, message ?: "The Auralis update was not installed.", Toast.LENGTH_LONG).show()
        }
    }
}
