// GhostShare's own Android source: build.zig copies it into the generated
// Gradle project (android/app/src/main/java/dev/ghostshare/) on every
// Android build, since Oriel 0.9.1 has no way to add app sources.
package dev.ghostshare

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import androidx.annotation.Keep
import dev.oriel.OrielRuntime

/**
 * The Quick Share wake-up beacon: a BLE advertisement of service data under
 * the 16-bit UUID 0xFE2C, which makes nearby Android phones start announcing
 * their Quick Share endpoint over mDNS (rquickshare's blea.rs does the same
 * with BlueZ on Linux). Legacy advertising, non-connectable, no flags, name
 * or TX power: 28 bytes, within the 31 a legacy advertisement carries.
 *
 * Also manages the Android Wi-Fi MulticastLock required for mDNS discovery.
 * Without this lock, Android drops multicast packets to 224.0.0.251:5353.
 */
@Keep
object QuickShareBeacon {
    private const val TAG = "GhostShare"
    private val SERVICE_UUID: ParcelUuid = ParcelUuid.fromString("0000FE2C-0000-1000-8000-00805F9B34FB")
    // vendor/rquickshare/src/hdl/blea.rs SERVICE_DATA.
    private val SERVICE_DATA: ByteArray = intArrayOf(
        252, 18, 142, 1, 66, 0, 0, 0, 0, 0, 0, 0, 0, 0, 191, 45, 91, 160, 225, 216, 117, 36, 202, 0,
    ).map { it.toByte() }.toByteArray()
    /** A request code Oriel's permission handler ignores. */
    private const val REQUEST_CODE = 0x4F2C
    private const val PERMISSION_POLL_MS = 1000L
    private const val PERMISSION_POLL_MAX = 120

    private val main = Handler(Looper.getMainLooper())
    @Volatile private var wanted = false
    private var advertiser: BluetoothLeAdvertiser? = null
    private var receiver: BroadcastReceiver? = null
    private var permissionAsked = false
    private var multicastLock: WifiManager.MulticastLock? = null

    private val callback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            Log.i(TAG, "Quick Share BLE beacon: advertising (mode ${settingsInEffect.mode}, tx ${settingsInEffect.txPowerLevel})")
        }

        override fun onStartFailure(errorCode: Int) {
            advertiser = null
            val why = when (errorCode) {
                ADVERTISE_FAILED_DATA_TOO_LARGE -> "data too large"
                ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "too many advertisers"
                ADVERTISE_FAILED_ALREADY_STARTED -> "already started"
                ADVERTISE_FAILED_INTERNAL_ERROR -> "internal error"
                ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "unsupported"
                else -> "unknown"
            }
            Log.w(TAG, "Quick Share BLE beacon: start failed, code $errorCode ($why)")
        }
    }

    /** Advertise until `stop` and hold the Wi-Fi multicast lock for discovery (any thread). */
    @JvmStatic
    fun start() {
        main.post {
            acquireMulticast()
            if (wanted) return@post
            wanted = true
            watchAdapter()
            if (hasPermission()) advertise() else askPermission()
        }
    }

    /** Stop advertising and release multicast lock (any thread). */
    @JvmStatic
    fun stop() {
        synchronized(this) {
            wanted = false
            stopAdvertising()
        }
        main.post {
            releaseMulticast()
            receiver?.let { r -> try { OrielRuntime.app.unregisterReceiver(r) } catch (_: Exception) {} }
            receiver = null
        }
    }

    /** Explicitly acquire the Wi-Fi MulticastLock for mDNS discovery (any thread). */
    @JvmStatic
    fun acquireMulticastLock() {
        main.post { acquireMulticast() }
    }

    /** Explicitly release the Wi-Fi MulticastLock (any thread). */
    @JvmStatic
    fun releaseMulticastLock() {
        main.post { releaseMulticast() }
    }

    private fun acquireMulticast() {
        if (multicastLock != null && multicastLock?.isHeld == true) return
        try {
            val wifi = OrielRuntime.app.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            multicastLock = wifi?.createMulticastLock("GhostShare mDNS")?.apply {
                setReferenceCounted(false)
                acquire()
                Log.i(TAG, "Quick Share: Wi-Fi MulticastLock acquired")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Quick Share: failed to acquire MulticastLock", e)
        }
    }

    private fun releaseMulticast() {
        try {
            multicastLock?.let {
                if (it.isHeld) it.release()
                Log.i(TAG, "Quick Share: Wi-Fi MulticastLock released")
            }
            multicastLock = null
        } catch (e: Exception) {
            Log.w(TAG, "Quick Share: failed to release MulticastLock", e)
        }
    }

    private fun permissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= 33) {
            arrayOf(
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.NEARBY_WIFI_DEVICES,
            )
        } else if (Build.VERSION.SDK_INT >= 31) {
            arrayOf(Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            // Normal permissions up to API 30: granted at install.
            arrayOf(Manifest.permission.BLUETOOTH, Manifest.permission.BLUETOOTH_ADMIN)
        }

    private fun hasPermission(): Boolean {
        val app = OrielRuntime.app
        val needed = if (Build.VERSION.SDK_INT >= 31) Manifest.permission.BLUETOOTH_ADVERTISE else Manifest.permission.BLUETOOTH_ADMIN
        return app.checkSelfPermission(needed) == PackageManager.PERMISSION_GRANTED
    }

    /** Show the "Nearby devices" prompt, then advertise once it is granted. */
    private fun askPermission() {
        if (!permissionAsked) {
            val host = OrielRuntime.foreground
            if (host == null) {
                // If foreground activity is not yet ready, retry shortly
                main.postDelayed({ if (wanted && !hasPermission()) askPermission() }, 500L)
                return
            }
            permissionAsked = true
            Log.i(TAG, "Quick Share BLE beacon: asking for the Nearby devices permission")
            host.requestPermissions(permissions(), REQUEST_CODE)
        }
        // The answer goes to Oriel's activity, which ignores this request
        // code: check for the grant instead.
        var polls = 0
        val check = object : Runnable {
            override fun run() {
                if (!wanted) return
                if (hasPermission()) return advertise()
                if (++polls < PERMISSION_POLL_MAX) main.postDelayed(this, PERMISSION_POLL_MS)
                else Log.w(TAG, "Quick Share BLE beacon: Nearby devices permission not granted")
            }
        }
        main.postDelayed(check, PERMISSION_POLL_MS)
    }

    /** Advertise again when the adapter comes on; drop the advertiser when it goes off. */
    private fun watchAdapter() {
        if (receiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                    BluetoothAdapter.STATE_ON -> if (wanted && hasPermission()) advertise()
                    BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> synchronized(this@QuickShareBeacon) { stopAdvertising() }
                }
            }
        }
        val app = OrielRuntime.app
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(r, filter, Context.RECEIVER_EXPORTED) else app.registerReceiver(r, filter)
        receiver = r
    }

    private fun advertise() {
        synchronized(this) {
            if (!wanted || advertiser != null) return
            val adapter = OrielRuntime.app.getSystemService(BluetoothManager::class.java)?.adapter
            if (adapter == null) {
                Log.i(TAG, "Quick Share BLE beacon: no Bluetooth adapter")
                return
            }
            if (!adapter.isEnabled) {
                Log.i(TAG, "Quick Share BLE beacon: Bluetooth is off; waiting for it")
                return
            }
            val le = adapter.bluetoothLeAdvertiser
            if (le == null) {
                Log.w(TAG, "Quick Share BLE beacon: adapter has no BLE advertiser")
                return
            }
            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                .setConnectable(false)
                .setTimeout(0)
                .build()
            val data = AdvertiseData.Builder()
                .addServiceData(SERVICE_UUID, SERVICE_DATA)
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .build()
            advertiser = le
            le.startAdvertising(settings, data, callback)
        }
    }

    private fun stopAdvertising() {
        val le = advertiser ?: return
        advertiser = null
        try {
            le.stopAdvertising(callback)
            Log.i(TAG, "Quick Share BLE beacon: stopped")
        } catch (e: Exception) {
            Log.w(TAG, "Quick Share BLE beacon: stopAdvertising failed", e)
        }
    }
}
