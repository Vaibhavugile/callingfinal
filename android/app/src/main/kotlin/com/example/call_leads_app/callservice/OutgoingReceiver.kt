package com.example.call_leads_app.callservice

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.google.firebase.crashlytics.FirebaseCrashlytics
import java.util.UUID

class OutgoingReceiver : BroadcastReceiver() {
    private val TAG = "OutgoingReceiver"

    private val PREFS = "call_leads_prefs"
    private val KEY_LAST_OUTGOING = "last_outgoing_number"
    private val KEY_LAST_OUTGOING_TS = "last_outgoing_ts"

    // Active/recency semantics (keep consistent with other components)
    private val REUSE_WINDOW_MS = 120_000L            // 2 minutes fallback
    private val ACTIVE_CALL_TTL_MS = 60 * 60 * 1000L // 1 hour active TTL

    override fun onReceive(context: Context?, intent: Intent?) {
        FirebaseCrashlytics.getInstance().log("OutgoingReceiver.onReceive triggered")
        try {
            Log.d(TAG, "📞 ACTION_NEW_OUTGOING_CALL received")

            if (context == null || intent == null) {
                Log.e(TAG, "Context or Intent null")
                return
            }

            val number = intent.getStringExtra(Intent.EXTRA_PHONE_NUMBER)

            if (number.isNullOrEmpty()) {
                Log.w(TAG, "Outgoing Number empty/null. Ignoring.")
                return
            }

            Log.d(TAG, "📞 Outgoing Number (raw): $number")
            FirebaseCrashlytics.getInstance().log("Outgoing rawNumber=$number")

            // normalize number to digits-only to keep canonical form across components
            val normalized = normalizeNumber(number)
            try {
                val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                if (!normalized.isNullOrEmpty()) {
                    prefs.edit().putString(KEY_LAST_OUTGOING, normalized).putLong(KEY_LAST_OUTGOING_TS, System.currentTimeMillis()).apply()
                    Log.d(TAG, "Saved outgoing marker: $normalized")
                    FirebaseCrashlytics.getInstance().log("Saved outgoing marker")
                } else {
                    Log.w(TAG, "Normalized outgoing number empty after cleanup. Using raw number instead.")
                    FirebaseCrashlytics.getInstance().log("Normalized outgoing empty")
                }

                // Try to reuse existing callId if present for normalized (lookup-first)
                val markerKey = if (!normalized.isNullOrEmpty()) normalized else number
                val existing = try {
                    readActiveOrRecentCallId(context, markerKey)
                } catch (e: Exception) {
                    FirebaseCrashlytics.getInstance().recordException(e)
                    Log.w(TAG, "readActiveOrRecentCallId threw: ${e.localizedMessage}")
                    null
                }
                val callId = try {
                    existing ?: ensureCallIdForPhone(context, markerKey)
                } catch (e: Exception) {
                    FirebaseCrashlytics.getInstance().recordException(e)
                    Log.w(TAG, "ensureCallIdForPhone threw: ${e.localizedMessage}")
                    generateCallId()
                }
                if (existing != null) {
                    Log.d(TAG, "Reusing existing callId marker for $markerKey -> $existing")
                    FirebaseCrashlytics.getInstance().log("Reused existing callId")
                } else {
                    Log.d(TAG, "Created new callId marker for $markerKey -> $callId")
                    FirebaseCrashlytics.getInstance().log("Created new callId marker")
                }

                // read tenantId from prefs and attach if present
                val tenant = try {
                    prefs.getString("tenantId", null)
                } catch (e: Exception) {
                    FirebaseCrashlytics.getInstance().recordException(e)
                    Log.w(TAG, "Failed reading tenantId from prefs: ${e.localizedMessage}")
                    null
                }
                if (tenant == null) {
                    Log.d(TAG, "OutgoingReceiver: no tenantId in prefs (proceeding without tenant).")
                } else {
                    Log.d(TAG, "OutgoingReceiver: attaching tenantId=$tenant to outgoing event.")
                    FirebaseCrashlytics.getInstance().log("Attaching tenantId=$tenant")
                }

                val serviceIntent = Intent(context, CallService::class.java).apply {
                    putExtra("direction", "outbound")
                    // prefer normalized if available, otherwise send raw
                    putExtra("phoneNumber", if (!normalized.isNullOrEmpty()) normalized else number)
                    putExtra("event", "outgoing_start")
                    putExtra("callId", callId)
                    putExtra("receivedAt", System.currentTimeMillis())
                    tenant?.let { putExtra("tenantId", it) }
                }

                try {
                    ContextCompat.startForegroundService(context, serviceIntent)
                    Log.d(TAG, "Started CallService for outgoing_start (callId=$callId)")
                    FirebaseCrashlytics.getInstance().log("Started CallService for outgoing_start")

                    // Post the tap notification so user can quickly open the app/lead (mirrors incoming flow)
                    try {
                        postTapNotification(context, if (!normalized.isNullOrEmpty()) normalized else number)
                        Log.d(TAG, "Posted tap notification for outgoing call: ${if (!normalized.isNullOrEmpty()) normalized else number}")
                        FirebaseCrashlytics.getInstance().log("Posted tap notification")
                    } catch (ne: Exception) {
                        FirebaseCrashlytics.getInstance().recordException(ne)
                        Log.w(TAG, "postTapNotification failed: ${ne.localizedMessage}")
                    }
                } catch (e: Exception) {
                    FirebaseCrashlytics.getInstance().recordException(e)
                    Log.e(TAG, "Failed to start CallService for outgoing_start: ${e.localizedMessage}", e)
                }
            } catch (e: Exception) {
                FirebaseCrashlytics.getInstance().recordException(e)
                Log.e(TAG, "Error handling outgoing call: ${e.localizedMessage}", e)
            }
        } catch (t: Throwable) {
            FirebaseCrashlytics.getInstance().recordException(t)
            Log.e(TAG, "Unhandled error in OutgoingReceiver.onReceive: ${t.localizedMessage}", t)
        }
    }

    private fun normalizeNumber(n: String?): String? {
        if (n == null) return null
        val digits = n.filter { it.isDigit() }
        return if (digits.isEmpty()) null else digits
    }

    private fun generateCallId(): String {
        return "call_" + UUID.randomUUID().toString().replace("-", "").take(12)
    }

    // -----------------------
    // CallId lifecycle helpers (active & recent semantics)
    // -----------------------
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
            FirebaseCrashlytics.getInstance().log("markCallActiveForPhone written for $normalized")
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.w(TAG, "markCallActiveForPhone failed: ${e.localizedMessage}")
        }
    }

    private fun readActiveOrRecentCallId(ctx: Context, phoneDigitsOrRaw: String): String? {
        try {
            val normalized = normalizeNumber(phoneDigitsOrRaw) ?: phoneDigitsOrRaw
            val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val id = prefs.getString("callid_$normalized", null) ?: return null
            val now = System.currentTimeMillis()

            // check explicit active-until marker first
            val activeUntil = prefs.getLong("callid_active_until_$normalized", 0L)
            if (activeUntil > now) {
                Log.d(TAG, "Reusing ACTIVE callId for $normalized -> $id (activeUntil=$activeUntil)")
                FirebaseCrashlytics.getInstance().log("Reusing ACTIVE callId for $normalized")
                return id
            }

            // fallback: allow short reuse window if active marker expired but ts is recent
            val ts = prefs.getLong("callid_ts_$normalized", 0L)
            if (ts != 0L && (now - ts) <= REUSE_WINDOW_MS) {
                Log.d(TAG, "Reusing RECENT callId for $normalized -> $id (ts=$ts)")
                FirebaseCrashlytics.getInstance().log("Reusing RECENT callId for $normalized")
                return id
            }

            // too old / not active
            return null
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.w(TAG, "readActiveOrRecentCallId failed: ${e.localizedMessage}")
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
            FirebaseCrashlytics.getInstance().log("Cleared callId mapping for $normalized")
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.w(TAG, "clearCallIdMapping failed: ${e.localizedMessage}")
        }
    }

    /**
     * Backward-compatible ensure: returns existing mapping if present, otherwise creates a new callId
     * and marks it active (writes timestamp, active-until and reverse mapping).
     */
    private fun ensureCallIdForPhone(ctx: Context, phoneDigitsOrRaw: String): String {
        try {
            val normalized = normalizeNumber(phoneDigitsOrRaw) ?: phoneDigitsOrRaw
            if (normalized.isNullOrEmpty()) return generateCallId()
            val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val existing = prefs.getString("callid_$normalized", null)
            if (!existing.isNullOrEmpty()) {
                // backfill timestamp if missing
                val ts = prefs.getLong("callid_ts_$normalized", 0L)
                if (ts == 0L) prefs.edit().putLong("callid_ts_$normalized", System.currentTimeMillis()).apply()
                FirebaseCrashlytics.getInstance().log("ensureCallIdForPhone: reused existing for $normalized")
                return existing
            }

            val newId = generateCallId()
            markCallActiveForPhone(ctx, normalized, newId)
            Log.d(TAG, "ensureCallIdForPhone created and marked active: $normalized -> $newId")
            FirebaseCrashlytics.getInstance().log("ensureCallIdForPhone created $newId for $normalized")
            return newId
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.w(TAG, "ensureCallIdForPhone failed: ${e.localizedMessage}")
        }
        // fallback
        return generateCallId()
    }

    // -----------------------
    // Notification helper (tap to open app; includes phone extra "open_lead_phone")
    // -----------------------
    private fun postTapNotification(context: Context, phone: String?) {
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val NOTIF_CHANNEL_ID = "call_lead_channel"
            val NOTIF_ID_LEAD = 2401

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val ch = NotificationChannel(
                    NOTIF_CHANNEL_ID,
                    "Call leads",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    setShowBadge(false)
                }
                nm.createNotificationChannel(ch)
            }

            // Launcher intent — opens the app. We add an extra so MainActivity can deep-link to the lead if you already handle it.
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (launch != null) {
                launch.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                if (!phone.isNullOrEmpty()) launch.putExtra("open_lead_phone", phone)
            }

            val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }

            val pending = PendingIntent.getActivity(
                context,
                0,
                launch,
                pendingFlags
            )

            val notif = NotificationCompat.Builder(context, NOTIF_CHANNEL_ID)
                .setContentTitle("Call in progress")
                .setContentText(if (!phone.isNullOrEmpty()) "Tap to open lead for $phone" else "Tap to open lead")
                .setSmallIcon(android.R.drawable.sym_call_outgoing)
                .setContentIntent(pending)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .build()

            nm.notify(NOTIF_ID_LEAD, notif)
            FirebaseCrashlytics.getInstance().log("postTapNotification shown for $phone")
        } catch (ex: Exception) {
            FirebaseCrashlytics.getInstance().recordException(ex)
            Log.e(TAG, "Failed to post notification: ${ex.localizedMessage}", ex)
        }
    }
}
