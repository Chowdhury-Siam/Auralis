package com.auralis.siam

import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageInstaller
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class UpdateInstallReceiverTest {
    @Test fun opensConfirmationOnlyWhenAndroidRequiresIt() {
        var opened: Intent? = null
        val context = object : ContextWrapper(null) {
            override fun startActivity(intent: Intent) { opened = intent }
        }
        val receiver = UpdateInstallReceiver()
        val callback = Intent(UpdateInstallReceiver.ACTION)
            .putExtra(PackageInstaller.EXTRA_SESSION_ID, 123)
            .putExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_SUCCESS)
        receiver.onReceive(context, callback)
        assertNull(opened)

        callback.putExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_PENDING_USER_ACTION)
            .putExtra(Intent.EXTRA_INTENT, Intent("synthetic.confirm.update"))
        receiver.onReceive(context, callback)
        assertEquals("synthetic.confirm.update", opened?.action)
        assertTrue(opened!!.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
    }
}
