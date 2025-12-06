package com.example.call_leads_app.callservice

import android.content.Intent
import android.net.Uri
import android.telecom.CallRedirectionService
import android.telecom.PhoneAccountHandle
import android.util.Log
import androidx.core.content.ContextCompat
import com.google.firebase.crashlytics.FirebaseCrashlytics
import java.util.UUID

class MyCallRedirectionService : CallRedirectionService() {

    private val TAG = "MyCallRedirectionService"
    private val PREFS = "call_leads_prefs"
    private val KEY_LAST_OUTGOING = "last_outgoing_number"
    private val KEY_LAST_OUTGOING_TS = "last_outgoing_ts"

    // Active/recency semantics (keep in sync with CallService)
    private val REUSE_WINDOW_MS = 120_000L            // 2 minutes fallback
    private val ACTIVE_CALL_TTL_MS = 60 * 60 * 1000L // 1 hour active TTL

    private val CALL_SERVICE_CLASS_NAME = "com.example.call_leads_app.callservice.CallService"

    override fun onPlaceCall(handle: Uri, phoneAccount: PhoneAccountHandle, allowInteractiveResponse: Boolean) {
        FirebaseCrashlytics.getInstance().log("MyCallRedirectionService.onPlaceCall triggered")
        try {
            val phoneNumber = handle.schemeSpecificPart
            Log.d(TAG, "onPlaceCall: $phoneNumber")

            val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)

            // normalize first
            val normalized = normalizeNumber(phoneNumber) ?: phoneNumber

            // save outgoing marker
            try {
                prefs.edit()
                    .putString(KEY_LAST_OUTGOING, normalized)
                    .putLong(KEY_LAST_OUTGOING_TS, System.currentTimeMillis())
                    .apply()
                FirebaseCrashlytics.getInstance().log("Saved outgoing marker for $normalized")
                Log.d(TAG, "Saved outgoing marker for $normalized")
            } catch (e: Exception) {
                FirebaseCrashlytics.getInstance().recordException(e)
                Log.w(TAG, "Failed to save outgoing marker: ${e.localizedMessage}")
            }

            // lookup-first: reuse callId if exists (active-or-recent), otherwise create & mark active
            val existing = try {
                readActiveOrRecentCallId(this, normalized)
            } catch (e: Exception) {
                FirebaseCrashlytics.getInstance().recordException(e)
                Log.w(TAG, "readActiveOrRecentCallId threw: ${e.localizedMessage}")
                null
            }

            val callId = try {
                existing ?: ensureCallIdForPhone(this, normalized)
            } catch (e: Exception) {
                FirebaseCrashlytics.getInstance().recordException(e)
                Log.w(TAG, "ensureCallIdForPhone threw: ${e.localizedMessage}")
                generateCallId()
            }

            if (existing != null) {
                Log.d(TAG, "Reused existing callId for $normalized -> $existing")
                FirebaseCrashlytics.getInstance().log("Reused callId for $normalized")
            } else {
                Log.d(TAG, "Saved callId marker for $normalized -> $callId (and reverse mapping)")
                FirebaseCrashlytics.getInstance().log("Created callId for $normalized")
            }

            // read tenant and attach if present
            val tenant = try {
                prefs.getString("tenantId", null)
            } catch (e: Exception) {
                FirebaseCrashlytics.getInstance().recordException(e)
                Log.w(TAG, "Failed reading tenantId: ${e.localizedMessage}")
                null
            }

            val intent = Intent().apply {
                setClassName(packageName, CALL_SERVICE_CLASS_NAME)
                putExtra("event", "outgoing_start")
                putExtra("direction", "outbound")
                putExtra("phoneNumber", normalized)
                putExtra("callId", callId)
                putExtra("receivedAt", System.currentTimeMillis())
                tenant?.let { putExtra("tenantId", it) }
            }

            Log.d(TAG, "Starting CallService for outgoing_start with callId=$callId and tenant=$tenant")
            try {
                ContextCompat.startForegroundService(this, intent)
                FirebaseCrashlytics.getInstance().log("Started CallService for outgoing_start")
            } catch (e: Exception) {
                // If starting the foreground service fails, record and continue — callers should still place the call.
                FirebaseCrashlytics.getInstance().recordException(e)
                Log.w(TAG, "startForegroundService failed in MyCallRedirectionService: ${e.localizedMessage}")
            }

            // Always call placeCallUnmodified() (or cancelCall() on fatal error)
            try {
                placeCallUnmodified()
            } catch (e: Exception) {
                FirebaseCrashlytics.getInstance().recordException(e)
                Log.w(TAG, "placeCallUnmodified threw: ${e.localizedMessage}")
            }
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.e(TAG, "Error in onPlaceCall: ${e.localizedMessage}", e)
            try {
                cancelCall()
            } catch (ex: Exception) {
                FirebaseCrashlytics.getInstance().recordException(ex)
                Log.w(TAG, "cancelCall threw after onPlaceCall failure: ${ex.localizedMessage}")
            }
        }
    }

    private fun normalizeNumber(n: String?): String? {
        if (n == null) return null
        val digits = n.filter { it.isDigit() }
        return if (digits.isEmpty()) null else digits
    }

    // -----------------------
    // CallId lifecycle helpers (active + recent semantics)
    // -----------------------
    private fun markCallActiveForPhone(ctx: android.content.Context, phoneDigitsOrRaw: String, callId: String) {
        FirebaseCrashlytics.getInstance().log("markCallActiveForPhone for $phoneDigitsOrRaw -> $callId")
        try {
            val normalized = normalizeNumber(phoneDigitsOrRaw) ?: phoneDigitsOrRaw
            val prefs = ctx.getSharedPreferences(PREFS, android.content.Context.MODE_PRIVATE)
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
            Log.w(TAG, "markCallActiveForPhone failed: ${e.localizedMessage}")
        }
    }

    private fun readActiveOrRecentCallId(ctx: android.content.Context, phoneDigitsOrRaw: String): String? {
        try {
            val normalized = normalizeNumber(phoneDigitsOrRaw) ?: phoneDigitsOrRaw
            val prefs = ctx.getSharedPreferences(PREFS, android.content.Context.MODE_PRIVATE)
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
            Log.w(TAG, "readActiveOrRecentCallId failed: ${e.localizedMessage}")
            return null
        }
    }

    private fun ensureCallIdForPhone(ctx: android.content.Context, phoneDigitsOrRaw: String?): String {
        try {
            val normalized = normalizeNumber(phoneDigitsOrRaw) ?: phoneDigitsOrRaw ?: return generateCallId()
            val prefs = ctx.getSharedPreferences(PREFS, android.content.Context.MODE_PRIVATE)
            val existing = prefs.getString("callid_$normalized", null)
            if (!existing.isNullOrEmpty()) return existing

            val newId = generateCallId()
            // mark active (this writes callid_, ts and active_until and reverse mapping)
            markCallActiveForPhone(ctx, normalized, newId)
            Log.d(TAG, "ensureCallIdForPhone created and marked active: $normalized -> $newId")
            return newId
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.w(TAG, "ensureCallIdForPhone failed: ${e.localizedMessage}")
        }
        return generateCallId()
    }

    private fun generateCallId(): String {
        return "call_" + UUID.randomUUID().toString().replace("-", "").take(12)
    }
}
