package com.example.call_leads_app

import android.app.Activity
import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.CallLog
import android.util.Log
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import com.google.firebase.crashlytics.FirebaseCrashlytics
import java.util.Calendar

class MainActivity : FlutterActivity() {

    private val CALL_EVENTS = "com.example.call_leads_app/callEvents"
    private val NATIVE_CHANNEL = "com.example.call_leads_app/native"
    private val OPEN_LEAD_CHANNEL = "com.example.call_leads_app/openLead"
    private val TAG = "MainActivity"
    private val REQUEST_ROLE_DIALER = 32123

    private var openLeadMethodChannel: MethodChannel? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        try {
            val crashlytics = FirebaseCrashlytics.getInstance()
            crashlytics.setCustomKey("device_model", Build.MODEL ?: "unknown")
            crashlytics.setCustomKey("os_version", Build.VERSION.RELEASE ?: "unknown")

            // 🔥 TEST CRASHLYTICS EVENT (Non-fatal)
            // This will appear in Firebase → Crashlytics → Non-fatal
            FirebaseCrashlytics.getInstance().recordException(
                Exception("TEST_NON_FATAL_CRASH_FROM_MAINACTIVITY")
            )

        } catch (e: Exception) {
            Log.w(TAG, "Crashlytics init failed: ${e.localizedMessage}")
        }

        // -------------------
        // EVENT CHANNEL SETUP
        // -------------------
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CALL_EVENTS
        ).setStreamHandler(object : EventChannel.StreamHandler {

            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                try {
                    Log.d(TAG, "Flutter EventChannel LISTEN attached.")

                    com.example.call_leads_app.callservice.CallService.eventSink = events
                    com.example.call_leads_app.callservice.CallService.flushPendingToSink()

                } catch (e: Exception) {
                    Log.e(TAG, "onListen error: ${e.localizedMessage}", e)
                }
            }

            override fun onCancel(arguments: Any?) {
                try {
                    Log.d(TAG, "Flutter EventChannel CANCEL called — clearing sink.")
                    com.example.call_leads_app.callservice.CallService.eventSink = null
                } catch (e: Exception) {
                    Log.e(TAG, "onCancel error: ${e.localizedMessage}", e)
                }
            }
        })

        // -------------------
        // METHOD CHANNEL SETUP
        // -------------------
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NATIVE_CHANNEL
        ).setMethodCallHandler { call, result ->

            when (call.method) {

                "requestDialerRole" -> {
                    val ok = requestDialerRole()
                    result.success(ok)
                }

                "flushPendingEvents" -> {
                    try {
                        Log.d(TAG, "Manual flushPendingEvents() called from Flutter")
                        com.example.call_leads_app.callservice.CallService.flushPendingToSink()
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(TAG, "flushPendingEvents error: ${e.localizedMessage}", e)
                        result.success(false)
                    }
                }

                "setTenantId" -> {
                    try {
                        val tenantId = call.argument<String>("tenantId")
                        if (!tenantId.isNullOrEmpty()) {
                            val prefs = getSharedPreferences("call_leads_prefs", Context.MODE_PRIVATE)
                            prefs.edit().putString("tenantId", tenantId).apply()
                            Log.d(TAG, "Native: saved tenantId=$tenantId")
                            result.success(true)
                        } else {
                            Log.w(TAG, "setTenantId called with empty tenantId")
                            result.success(false)
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "setTenantId error: ${e.localizedMessage}", e)
                        result.success(false)
                    }
                }

                "clearTenantId" -> {
                    try {
                        val prefs = getSharedPreferences("call_leads_prefs", Context.MODE_PRIVATE)
                        prefs.edit().remove("tenantId").apply()
                        Log.d(TAG, "Native: cleared tenantId from prefs")
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(TAG, "clearTenantId error: ${e.localizedMessage}", e)
                        result.success(false)
                    }
                }

                // 🔹 NEW: return today's call-log rows to Flutter
                "getTodayCallLog" -> {
                    try {
                        val rows = getTodayCallLogRows()
                        result.success(rows)
                    } catch (e: Exception) {
                        Log.e(TAG, "getTodayCallLog error: ${e.localizedMessage}", e)
                        result.error("CALLLOG_ERROR", e.localizedMessage, null)
                    }
                }

                else -> result.notImplemented()
            }
        }

        // -------------------
        // OPEN LEAD METHOD CHANNEL
        // -------------------
        openLeadMethodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, OPEN_LEAD_CHANNEL)

        handleIntentForOpenLead(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntentForOpenLead(intent)
    }

    private fun handleIntentForOpenLead(intent: Intent?) {
        val phone = intent?.getStringExtra("open_lead_phone")
        if (!phone.isNullOrEmpty()) {
            Log.d(TAG, "handleIntentForOpenLead: forwarding open_lead_phone=$phone to Flutter")
            try {
                openLeadMethodChannel?.invokeMethod("openLeadByPhone", mapOf("phone" to phone))
            } catch (e: Exception) {
                Log.w(TAG, "invokeMethod failed: ${e.localizedMessage}")
                Handler(Looper.getMainLooper()).postDelayed({
                    try {
                        openLeadMethodChannel?.invokeMethod("openLeadByPhone", mapOf("phone" to phone))
                    } catch (ex: Exception) {
                        Log.e(TAG, "Retry invokeMethod failed: ${ex.localizedMessage}", ex)
                    }
                }, 300)
            }
        }
    }

    private fun requestDialerRole(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            Log.w(TAG, "ROLE_DIALER requires API 29+. Skipped.")
            return false
        }

        val roleManager = getSystemService(Context.ROLE_SERVICE) as? RoleManager ?: return false

        return try {
            if (!roleManager.isRoleHeld(RoleManager.ROLE_DIALER)) {
                val intent = roleManager.createRequestRoleIntent(RoleManager.ROLE_DIALER)
                startActivityForResult(intent, REQUEST_ROLE_DIALER)
                true
            } else {
                Log.d(TAG, "Already default dialer.")
                true
            }
        } catch (e: Exception) {
            Log.e(TAG, "requestDialerRole error: ${e.localizedMessage}", e)
            false
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == REQUEST_ROLE_DIALER) {
            if (resultCode == Activity.RESULT_OK) {
                Log.d(TAG, "User granted default dialer role.")
            } else {
                Log.d(TAG, "User rejected default dialer role.")
            }
        }
    }

    // --------------------------------------------------------------------
    // 🔹 NEW HELPERS FOR CALL-LOG → (outcome, direction) + normalization
    // --------------------------------------------------------------------

    // Decide final outcome + direction from CallLog row
private fun mapOutcomeAndDirection(callType: Int, duration: Int): Pair<String, String> {
    return when (callType) {
        // Incoming:
        //  - if duration > 0 → answered+ended
        //  - if duration == 0 → missed
        CallLog.Calls.INCOMING_TYPE -> {
            if (duration > 0) {
                "ended" to "inbound"
            } else {
                "missed" to "inbound"
            }
        }

        // Outgoing: treat everything as a completed outgoing call,
        // using duration (0 or >0) as provided by call log.
        CallLog.Calls.OUTGOING_TYPE -> {
            "ended" to "outbound"
        }

        // Explicit missed entries
        CallLog.Calls.MISSED_TYPE -> {
            "missed" to "inbound"
        }

        // Voicemail as inbound
        CallLog.Calls.VOICEMAIL_TYPE -> {
            "voicemail" to "inbound"
        }

        // Many OEMs use 5 for rejected
        5 -> {
            "rejected" to "inbound"
        }

        // Answered on another device
        CallLog.Calls.ANSWERED_EXTERNALLY_TYPE -> {
            "answered_external" to "inbound"
        }

        // Fallback: inbound ended
        else -> {
            "ended" to "inbound"
        }
    }
}


    private fun normalizeNumber(n: String?): String {
        if (n == null) return ""
        val digits = n.filter { it.isDigit() }
        return digits
    }

    // --------------------------------------------------------------------
    // 🔹 NEW: fetch today's call-log rows (used by getTodayCallLog)
    // --------------------------------------------------------------------
    private fun getTodayCallLogRows(): List<Map<String, Any?>> {
    val out = mutableListOf<Map<String, Any?>>()

    // Make sure READ_CALL_LOG is granted
    if (checkSelfPermission(android.Manifest.permission.READ_CALL_LOG)
        != PackageManager.PERMISSION_GRANTED
    ) {
        Log.w(TAG, "READ_CALL_LOG not granted; returning empty list.")
        return out
    }

    val cal = Calendar.getInstance()
    cal.timeInMillis = System.currentTimeMillis()
    cal.set(Calendar.HOUR_OF_DAY, 0)
    cal.set(Calendar.MINUTE, 0)
    cal.set(Calendar.SECOND, 0)
    cal.set(Calendar.MILLISECOND, 0)
    val startOfDayMs = cal.timeInMillis

    val limitUri = CallLog.Calls.CONTENT_URI.buildUpon()
        .appendQueryParameter("limit", "200") // safety limit
        .build()

    val projection = arrayOf(
        CallLog.Calls.NUMBER,
        CallLog.Calls.TYPE,
        CallLog.Calls.DATE,
        CallLog.Calls.DURATION
    )

    val selection = "${CallLog.Calls.DATE}>=?"
    val selectionArgs = arrayOf(startOfDayMs.toString())

    val cr = contentResolver
    val cursor = try {
        cr.query(
            limitUri,
            projection,
            selection,
            selectionArgs,
            "${CallLog.Calls.DATE} DESC"
        )
    } catch (e: Exception) {
        Log.e(TAG, "CallLog query failed: ${e.localizedMessage}", e)
        null
    }

    cursor?.use { c ->
        val idxNumber = c.getColumnIndexOrThrow(CallLog.Calls.NUMBER)
        val idxType = c.getColumnIndexOrThrow(CallLog.Calls.TYPE)
        val idxDate = c.getColumnIndexOrThrow(CallLog.Calls.DATE)
        val idxDur = c.getColumnIndexOrThrow(CallLog.Calls.DURATION)

        while (c.moveToNext()) {
            try {
                val rawNumber = c.getString(idxNumber)
                val type = c.getInt(idxType)
                val ts = c.getLong(idxDate)
                val durRaw = c.getInt(idxDur)

                // Always keep duration >= 0
                val safeDur = if (durRaw >= 0) durRaw else 0

                val (outcome, direction) = mapOutcomeAndDirection(type, safeDur)
                val normalized = normalizeNumber(rawNumber)

                if (normalized.isEmpty()) continue

                out.add(
                    mapOf(
                        "phoneNumber" to normalized,
                        "direction" to direction,
                        "outcome" to outcome,
                        "timestamp" to ts,
                        "durationInSeconds" to safeDur,  // always present (0+)
                    )
                )
            } catch (e: Exception) {
                Log.w(TAG, "Error reading call log row: ${e.localizedMessage}", e)
            }
        }
    }

    Log.d(TAG, "getTodayCallLogRows -> ${out.size} rows")
    return out
}

}
