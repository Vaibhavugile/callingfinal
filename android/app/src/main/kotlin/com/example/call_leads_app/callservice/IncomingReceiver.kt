package com.example.call_leads_app.callservice

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.telephony.TelephonyManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.work.Data
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import java.util.UUID
import com.google.firebase.crashlytics.FirebaseCrashlytics


/**
 * Robust IncomingReceiver:
 *  - Attempts ContextCompat.startForegroundService() normally.
 *  - If the OS refuses (IllegalStateException / SecurityException / other Exceptions),
 *    enqueues EnqueueEventWorker with the same payload so UploadWorker will handle sending later.
 *  - Posts a lightweight tap notification for the user in fallback cases so they can open the app.
 *
 * This reduces ForegroundServiceDidNotStartInTimeException on strict OEMs while preserving functionality.
 */
class IncomingReceiver : BroadcastReceiver() {

    private val TAG = "IncomingReceiver"
    private val PREFS = "call_leads_prefs"
    private val KEY_LAST_OUTGOING = "last_outgoing_number"
    private val KEY_LAST_OUTGOING_TS = "last_outgoing_ts"
    private val OUTGOING_MARKER_WINDOW_MS = 12_000L // slightly larger window

    // Active/recency semantics (keep in sync with CallService)
    private val REUSE_WINDOW_MS = 120_000L            // 2 minutes fallback
    private val ACTIVE_CALL_TTL_MS = 60 * 60 * 1000L // 1 hour active TTL

    private val NOTIF_CHANNEL_ID = "call_lead_channel"
    private val NOTIF_ID_LEAD = 2401

    override fun onReceive(context: Context, intent: Intent) {
        FirebaseCrashlytics.getInstance().log("IncomingReceiver.onReceive triggered")
        try {
            val tmState = intent.getStringExtra(TelephonyManager.EXTRA_STATE)
            var incomingNumber: String? = null
            if (intent.hasExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)) {
                incomingNumber = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)
            }

            FirebaseCrashlytics.getInstance().log("IncomingReceiver: state=$tmState incoming=$incomingNumber")
            Log.d(TAG, "📞 Triggered by Phone State Change - state=$tmState incoming=$incomingNumber")

            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val lastOutgoing = prefs.getString(KEY_LAST_OUTGOING, null)
            val lastTs = prefs.getLong(KEY_LAST_OUTGOING_TS, 0L)
            val now = System.currentTimeMillis()
            val isRecentOutgoing = !lastOutgoing.isNullOrEmpty() && (now - lastTs) <= OUTGOING_MARKER_WINDOW_MS

            // normalize incoming early
            val normalizedIncoming = normalizeNumber(incomingNumber)

            // read tenant once and attach to intents
            val tenantId = try {
                prefs.getString("tenantId", null)
            } catch (e: Exception) {
                FirebaseCrashlytics.getInstance().recordException(e)
                null
            }

            // If we recently marked an outgoing call, treat the next OFFHOOK/RINGING as outbound
            if (isRecentOutgoing && normalizedIncoming != null) {
                if (numbersLikelyMatch(lastOutgoing, normalizedIncoming)) {
                    FirebaseCrashlytics.getInstance().log("Detected recent outgoing marker for $normalizedIncoming - treating as outbound")
                    Log.d(TAG, "ℹ️ Detected recent outgoing marker for $normalizedIncoming — treating as outbound and clearing marker.")
                    prefs.edit().remove(KEY_LAST_OUTGOING).remove(KEY_LAST_OUTGOING_TS).apply()

                    val existingCallId = readActiveOrRecentCallId(context, normalizedIncoming)
                    val callId = existingCallId ?: ensureCallIdForPhone(context, normalizedIncoming)
                    val outIntent = Intent(context, CallService::class.java).apply {
                        putExtra("event", "outgoing_start")
                        putExtra("direction", "outbound")
                        putExtra("phoneNumber", normalizedIncoming)
                        putExtra("callId", callId)
                        putExtra("receivedAt", now)
                        tenantId?.let { putExtra("tenantId", it) }
                    }
                    safeStartServiceOrEnqueue(context, outIntent, normalizedIncoming)
                    return
                }
            }

            when (tmState) {
                TelephonyManager.EXTRA_STATE_RINGING -> {
                    FirebaseCrashlytics.getInstance().log("IncomingReceiver: RINGING for $normalizedIncoming")
                    Log.d(TAG, "RINGING — new incoming call: $incomingNumber")
                    if (!normalizedIncoming.isNullOrEmpty()) {
                        val existing = readActiveOrRecentCallId(context, normalizedIncoming)
                        val callId = existing ?: ensureCallIdForPhone(context, normalizedIncoming)
                        if (existing != null) Log.d(TAG, "Reusing existing callId for RINGING: $normalizedIncoming -> $existing")

                        val i = Intent(context, CallService::class.java).apply {
                            putExtra("event", "ringing")
                            putExtra("direction", "inbound")
                            putExtra("phoneNumber", normalizedIncoming)
                            putExtra("callId", callId)
                            putExtra("receivedAt", now)
                            tenantId?.let { putExtra("tenantId", it) }
                        }
                        safeStartServiceOrEnqueue(context, i, normalizedIncoming)
                    } else {
                        Log.w(TAG, "Incoming number is null/empty for state RINGING. Ignoring event.")
                    }
                }
                TelephonyManager.EXTRA_STATE_OFFHOOK -> {
                    FirebaseCrashlytics.getInstance().log("IncomingReceiver: OFFHOOK for $normalizedIncoming")
                    Log.d(TAG, "OFFHOOK — call answered or started: $incomingNumber")

                    val callId = normalizedIncoming?.let { readActiveOrRecentCallId(context, it) } ?: run {
                        val cid = ensureCallIdForPhone(context, normalizedIncoming ?: incomingNumber)
                        cid ?: generateCallId()
                    }

                    try {
                        val markerPhone = normalizedIncoming ?: incomingNumber
                        if (!markerPhone.isNullOrEmpty() && !callId.isNullOrEmpty()) {
                            val prefsLocal = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                            prefsLocal.edit().putString("callid_to_phone_$callId", markerPhone).apply()
                        }
                    } catch (e: Exception) {
                        FirebaseCrashlytics.getInstance().recordException(e)
                        Log.w(TAG, "Failed to persist reverse mapping for OFFHOOK: ${e.message}")
                    }

                    val i = Intent(context, CallService::class.java).apply {
                        putExtra("event", "answered")
                        putExtra("direction", "inbound")
                        putExtra("phoneNumber", normalizedIncoming)
                        putExtra("callId", callId)
                        putExtra("receivedAt", now)
                        tenantId?.let { putExtra("tenantId", it) }
                    }
                    safeStartServiceOrEnqueue(context, i, normalizedIncoming)
                }
                TelephonyManager.EXTRA_STATE_IDLE -> {
                    FirebaseCrashlytics.getInstance().log("IncomingReceiver: IDLE for $normalizedIncoming")
                    Log.d(TAG, "IDLE — finalizing call for $incomingNumber")
                    val callId = normalizedIncoming?.let { readActiveOrRecentCallId(context, it) } ?: ensureCallIdForPhone(context, normalizedIncoming ?: incomingNumber)
                    try {
                        val markerPhone = normalizedIncoming ?: incomingNumber
                        if (!markerPhone.isNullOrEmpty() && !callId.isNullOrEmpty()) {
                            val prefsLocal = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                            prefsLocal.edit().putString("callid_to_phone_$callId", markerPhone).apply()
                        }
                    } catch (e: Exception) {
                        FirebaseCrashlytics.getInstance().recordException(e)
                        Log.w(TAG, "Failed to persist reverse mapping for IDLE: ${e.message}")
                    }

                    val i = Intent(context, CallService::class.java).apply {
                        putExtra("event", "ended")
                        putExtra("direction", "inbound")
                        putExtra("phoneNumber", normalizedIncoming)
                        putExtra("callId", callId)
                        putExtra("receivedAt", now)
                        tenantId?.let { putExtra("tenantId", it) }
                    }
                    safeStartServiceOrEnqueue(context, i, normalizedIncoming)
                }
                else -> {
                    Log.d(TAG, "Unhandled telephony state: $tmState")
                }
            }
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.e(TAG, "Error in onReceive: ${e.message}", e)
        }
    }

    /**
     * Try to start the CallService as a foreground service.
     * If that fails (some OEMs throw various exceptions), fallback to scheduling EnqueueEventWorker with the same payload.
     */
    private fun safeStartServiceOrEnqueue(ctx: Context, svcIntent: Intent, normalizedPhone: String?) {
        // Ensure receivedAt present so enqueue path has timestamp
        if (!svcIntent.hasExtra("receivedAt")) svcIntent.putExtra("receivedAt", System.currentTimeMillis())

        try {
            Log.d(TAG, "Attempting to start CallService (foreground) with extras=${svcIntent.extras?.keySet()}")
            ContextCompat.startForegroundService(ctx, svcIntent)
            Log.d(TAG, "ContextCompat.startForegroundService succeeded")
            return
        } catch (e: IllegalStateException) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.w(TAG, "IllegalStateException while starting foreground service: ${e.message}")
        } catch (e: SecurityException) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.w(TAG, "SecurityException starting service: ${e.message}")
        } catch (e: Exception) {
            // Catch-all for any other exception types that OEMs might throw/wrap
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.w(TAG, "General exception starting service: ${e.message}")
        }

        // START: fallback path -> persist via WorkManager (so UploadWorker picks up later)
        FirebaseCrashlytics.getInstance().log("safeStartServiceOrEnqueue: startForegroundService failed, enqueueing worker")
        try {
            // Build Data safely from extras
            val dataBuilder = Data.Builder()
            svcIntent.extras?.keySet()?.forEach { key ->
                try {
                    val v = svcIntent.extras?.get(key) ?: return@forEach
                    when (v) {
                        is String -> dataBuilder.putString(key, v)
                        is Int -> dataBuilder.putInt(key, v)
                        is Long -> dataBuilder.putLong(key, v)
                        is Boolean -> dataBuilder.putBoolean(key, v)
                        is Double -> dataBuilder.putDouble(key, v)
                        is Float -> dataBuilder.putFloat(key, v)
                        else -> {
                            // best-effort fallback
                            dataBuilder.putString(key, v.toString())
                        }
                    }
                } catch (ex: Exception) {
                    FirebaseCrashlytics.getInstance().recordException(ex)
                }
            }

            // Defensive: ensure tenantId present if available in prefs
            try {
                val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                val tenant = prefs.getString("tenantId", null)
                if (!tenant.isNullOrEmpty() && !dataBuilder.build().keyValueMap.containsKey("tenantId")) {
                    dataBuilder.putString("tenantId", tenant)
                }
            } catch (ex: Exception) {
                FirebaseCrashlytics.getInstance().recordException(ex)
            }

            // Ensure receivedAt
            if (!dataBuilder.build().keyValueMap.containsKey("receivedAt")) {
                dataBuilder.putLong("receivedAt", System.currentTimeMillis())
            }

            val inputData = dataBuilder.build()
            val work = OneTimeWorkRequestBuilder<EnqueueEventWorker>()
                .setInputData(inputData)
                .build()

            WorkManager.getInstance(ctx).enqueue(work)
            FirebaseCrashlytics.getInstance().log("Enqueued EnqueueEventWorker for $normalizedPhone")
            Log.w(TAG, "Fallback: Enqueued EnqueueEventWorker (service start failed). Input keys=${inputData.keyValueMap.keys}")

            // Post a small tap notification so user can open the app and inspect the lead (useful when service path failed)
            postTapNotification(ctx, normalizedPhone)
        } catch (ex: Exception) {
            FirebaseCrashlytics.getInstance().recordException(ex)
            Log.e(TAG, "Failed to enqueue fallback work: ${ex.message}", ex)
        }
    }

    private fun postTapNotification(context: Context, phone: String?) {
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val ch = NotificationChannel(NOTIF_CHANNEL_ID, "Call leads", NotificationManager.IMPORTANCE_HIGH)
                ch.setShowBadge(false)
                nm.createNotificationChannel(ch)
            }

            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            launch?.putExtra("open_lead_phone", phone)

            val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }

            val pending = PendingIntent.getActivity(context, phone?.hashCode() ?: 0, launch, pendingFlags)

            val notif = NotificationCompat.Builder(context, NOTIF_CHANNEL_ID)
                .setContentTitle("Call detected")
                .setContentText(if (!phone.isNullOrEmpty()) "Tap to open lead for $phone" else "Tap to open lead")
                .setSmallIcon(android.R.drawable.sym_call_incoming)
                .setContentIntent(pending)
                .setAutoCancel(true)
                .build()

            nm.notify(NOTIF_ID_LEAD, notif)
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.e(TAG, "Failed to post notification: ${e.message}", e)
        }
    }

    // Helpers
    private fun normalizeNumber(n: String?): String? {
        if (n == null) return null
        val digits = n.filter { it.isDigit() }
        return if (digits.isEmpty()) null else digits
    }

    private fun numbersLikelyMatch(a: String?, b: String?): Boolean {
        val na = normalizeNumber(a) ?: return false
        val nb = normalizeNumber(b) ?: return false
        if (na == nb) return true
        val len = 7
        val sa = if (na.length > len) na.substring(na.length - len) else na
        val sb = if (nb.length > len) nb.substring(nb.length - len) else nb
        return sa == sb
    }

    private fun generateCallId(): String {
        return "call_" + UUID.randomUUID().toString().replace("-", "").take(12)
    }

    private fun markCallActiveForPhone(ctx: Context, phoneDigitsOrRaw: String, callId: String) {
        try {
            val normalized = normalizeNumber(phoneDigitsOrRaw) ?: phoneDigitsOrRaw
            val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val now = System.currentTimeMillis()
            prefs.edit()
                .putString("callid_$normalized", callId)
                .putLong("callid_ts_$normalized", now)
                .putLong("callid_active_until_$normalized", now + ACTIVE_CALL_TTL_MS)
                .putString("callid_to_phone_$callId", normalized)
                .apply()
            Log.d(TAG, "Marked call active for $normalized -> $callId until ${now + ACTIVE_CALL_TTL_MS}")
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.w(TAG, "markCallActiveForPhone failed: ${e.message}")
        }
    }

    private fun readActiveOrRecentCallId(ctx: Context, phoneDigitsOrRaw: String): String? {
        try {
            val normalized = normalizeNumber(phoneDigitsOrRaw) ?: phoneDigitsOrRaw
            val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val id = prefs.getString("callid_$normalized", null) ?: return null
            val now = System.currentTimeMillis()

            val activeUntil = prefs.getLong("callid_active_until_$normalized", 0L)
            if (activeUntil > now) {
                Log.d(TAG, "Reusing ACTIVE callId for $normalized -> $id (activeUntil=$activeUntil)")
                return id
            }

            val ts = prefs.getLong("callid_ts_$normalized", 0L)
            if (ts != 0L && (now - ts) <= REUSE_WINDOW_MS) {
                Log.d(TAG, "Reusing RECENT callId for $normalized -> $id (ts=$ts)")
                return id
            }

            return null
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.w(TAG, "readActiveOrRecentCallId failed: ${e.message}")
            return null
        }
    }

    private fun clearCallIdMapping(ctx: Context, phoneDigitsOrRaw: String) {
        try {
            val normalized = normalizeNumber(phoneDigitsOrRaw) ?: phoneDigitsOrRaw
            val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            prefs.edit()
                .remove("callid_$normalized")
                .remove("callid_ts_$normalized")
                .remove("callid_active_until_$normalized")
                .apply()
            Log.d(TAG, "Cleared callId mapping for $normalized")
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.w(TAG, "clearCallIdMapping failed: ${e.message}")
        }
    }

    private fun ensureCallIdForPhone(ctx: Context, phoneDigitsOrRaw: String?): String? {
        try {
            val normalized = normalizeNumber(phoneDigitsOrRaw) ?: phoneDigitsOrRaw
            if (normalized.isNullOrEmpty()) return null
            val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val existing = prefs.getString("callid_$normalized", null)
            if (!existing.isNullOrEmpty()) {
                val ts = prefs.getLong("callid_ts_$normalized", 0L)
                if (ts == 0L) prefs.edit().putLong("callid_ts_$normalized", System.currentTimeMillis()).apply()
                return existing
            }

            val newId = generateCallId()
            markCallActiveForPhone(ctx, normalized, newId)
            Log.d(TAG, "Saved callId marker for $normalized -> $newId (ensureCallIdForPhone)")
            return newId
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.w(TAG, "ensureCallIdForPhone failed: ${e.message}")
        }
        return null
    }
}
