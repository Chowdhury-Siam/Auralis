package com.auralis.siam

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel

class DeviceSetup(private val activity: Activity) {
    companion object { const val NOTIFICATIONS_REQUEST = 4301 }
    private var pending: MethodChannel.Result? = null
    private val preferences get() = activity.getSharedPreferences("setup", Context.MODE_PRIVATE)
    fun status(): Map<String, Boolean> = mapOf(
        "notifications" to (activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).areNotificationsEnabled(),
        "battery" to (activity.getSystemService(Context.POWER_SERVICE) as PowerManager).isIgnoringBatteryOptimizations(activity.packageName)
    )
    fun notifications(result: MethodChannel.Result) {
        if (pending != null) { result.error("setup_busy", "A permission request is already open.", null); return }
        try {
            if (status()["notifications"] == true) { result.success(null); return }
            if (Build.VERSION.SDK_INT >= 33 &&
                activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
                (!preferences.getBoolean("notificationsAsked", false) ||
                    activity.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS))) {
                pending = result
                activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATIONS_REQUEST)
                preferences.edit().putBoolean("notificationsAsked", true).apply()
            } else {
                val intent = if (Build.VERSION.SDK_INT >= 26)
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${activity.packageName}"))
                activity.startActivity(intent)
                result.success(null)
            }
        } catch (_: Exception) {
            pending = null
            result.error("setup_notifications", "Notification settings could not be opened.", null)
        }
    }
    fun battery(result: MethodChannel.Result) {
        try {
            try { activity.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) }
            catch (_: Exception) {
                activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:${activity.packageName}")))
            }
            result.success(null)
        } catch (_: Exception) { result.error("setup_battery", "Battery settings could not be opened.", null) }
    }
    fun onPermissionsResult(requestCode: Int) {
        if (requestCode != NOTIFICATIONS_REQUEST) return
        pending?.success(null)
        pending = null
    }
    fun close() {
        pending?.error("setup_closed", "The notification request was closed. You can retry from Settings.", null)
        pending = null
    }
}
