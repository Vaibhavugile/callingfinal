package com.example.call_leads_app.callservice

import android.content.Context
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters
import com.google.firebase.crashlytics.FirebaseCrashlytics

/**
 * Worker used as a robust fallback when starting the foreground CallService fails.
 * Persists the incoming event into EventQueue so UploadWorker will pick it up later.
 *
 * - Preserves tenantId when present in inputData.
 * - Normalizes phone numbers to digits-only.
 * - Attempts to recover phoneNumber via callId using tryFindPhoneForCallId().
 * - Adds a receivedAt timestamp if missing.
 */
class EnqueueEventWorker(appContext: Context, workerParams: WorkerParameters) : Worker(appContext, workerParams) {
    private val TAG = "EnqueueEventWorker"

    // Keep constants in sync with CallService
    private val PREFS = "call_leads_prefs"
    private val REUSE_WINDOW_MS = 120_000L            // 2 minutes fallback
    private val ACTIVE_CALL_TTL_MS = 60 * 60 * 1000L // 1 hour active TTL

    override fun doWork(): Result {
        return try {
            val data = inputData
            val eventMap = mutableMapOf<String, Any?>()

            // Copy all allowed key/value pairs from inputData
            try {
                data.keyValueMap.forEach { (k, v) ->
                    eventMap[k] = v
                }
            } catch (e: Exception) {
                FirebaseCrashlytics.getInstance().recordException(e)
                Log.w(TAG, "Failed to copy inputData to map: ${e.localizedMessage}")
            }

            // --- Preserve tenantId if provided in inputData ---
            try {
                val inputTenant = data.getString("tenantId")
                if (!inputTenant.isNullOrEmpty()) {
                    eventMap["tenantId"] = inputTenant
                    Log.d(TAG, "Preserved tenantId from inputData: $inputTenant")
                }
            } catch (e: Exception) {
                FirebaseCrashlytics.getInstance().recordException(e)
                Log.w(TAG, "Error while preserving tenantId from inputData: ${e.localizedMessage}")
            }

            // Normalize phoneNumber if present (digits-only)
            val phoneRaw = when (val p = eventMap["phoneNumber"]) {
                is String -> p
                else -> null
            }
            val normalized = phoneRaw?.filter { it.isDigit() }
            if (!normalized.isNullOrEmpty()) {
                eventMap["phoneNumber"] = normalized
            } else if (phoneRaw != null) {
                // keep raw if normalization removed everything (defensive)
                eventMap["phoneNumber"] = phoneRaw
            }

            // If phoneNumber still missing but we have callId, try to recover phone using persisted callId markers
            if ((eventMap["phoneNumber"] == null || (eventMap["phoneNumber"] as? String).isNullOrEmpty())) {
                val callId = eventMap["callId"] as? String
                if (!callId.isNullOrEmpty()) {
                    var recovered: String? = null
                    var attempt = 0
                    while (attempt < 4 && recovered.isNullOrEmpty()) {
                        recovered = tryFindPhoneForCallId(applicationContext, callId)
                        if (!recovered.isNullOrEmpty()) break
                        try {
                            Thread.sleep(100)
                        } catch (ie: InterruptedException) {
                            // ignore
                        }
                        attempt++
                    }

                    if (!recovered.isNullOrEmpty()) {
                        val recoveredNorm = recovered.filter { it.isDigit() }
                        eventMap["phoneNumber"] = if (recoveredNorm.isNotEmpty()) recoveredNorm else recovered
                        Log.d(TAG, "Recovered phoneNumber=$recovered for callId=$callId (attempts=${attempt + 1})")
                    } else {
                        Log.w(TAG, "No phone mapping found for callId=$callId after retries; will enqueue without phone (UploadWorker may skip).")
                    }
                }
            }

            // Ensure there's a receivedAt timestamp for ordering/diagnostics
            if (eventMap["receivedAt"] == null) {
                eventMap["receivedAt"] = System.currentTimeMillis()
            }

            // Persist using EventQueue so UploadWorker will pick it up
            val q = EventQueue(applicationContext)
            q.enqueue(eventMap)
            Log.d(TAG, "Enqueued event (fallback) -> $eventMap (queueSize=${q.size()})")
            FirebaseCrashlytics.getInstance().log("Enqueued fallback event; queueSize=${q.size()}")

            // schedule UploadWorker (best-effort)
            try {
                UploadWorker.scheduleOnce(applicationContext)
            } catch (e: Exception) {
                FirebaseCrashlytics.getInstance().recordException(e)
                Log.w(TAG, "Failed to schedule UploadWorker: ${e.localizedMessage}")
            }

            Result.success()
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.e(TAG, "EnqueueEventWorker failed: ${e.localizedMessage}", e)
            Result.retry()
        }
    }

    /**
     * Fast lookup: check direct reverse mapping "callid_to_phone_<callId>" first.
     * Fallback: scan legacy "callid_<phone>" keys to find a matching callId.
     *
     * This enhanced version respects the "active" marker (callid_active_until_<phone>)
     * and a recent-time fallback (callid_ts_<phone>) to avoid returning very old mappings.
     */
    private fun tryFindPhoneForCallId(ctx: Context, callId: String): String? {
        try {
            val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            // direct mapping (fast)
            val direct = prefs.getString("callid_to_phone_$callId", null)
            if (!direct.isNullOrEmpty()) return direct

            // fallback: scan keys (backwards compatibility)
            val all = prefs.all
            val now = System.currentTimeMillis()

            for ((k, v) in all) {
                // Skip helper keys and reverse mappings
                if (k.startsWith("callid_to_phone_")) continue
                if (k.startsWith("callid_active_until_")) continue
                if (k.startsWith("callid_ts_")) continue

                // We're interested in keys like "callid_<normalizedPhone>"
                if (!k.startsWith("callid_")) continue
                val value = v as? String ?: continue
                if (value != callId) continue

                // found a candidate -> check activity/recency
                val normalized = k.removePrefix("callid_")
                // prefer active-until marker
                val activeUntil = prefs.getLong("callid_active_until_$normalized", 0L)
                if (activeUntil > now) {
                    // still active
                    return normalized
                }
                // fallback to timestamp recency
                val ts = prefs.getLong("callid_ts_$normalized", 0L)
                if (ts != 0L && (now - ts) <= REUSE_WINDOW_MS) {
                    return normalized
                }
                // else treat as too old, continue searching (there may be other keys)
            }
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.w(TAG, "Error while looking up callId mapping: ${e.localizedMessage}")
        }
        return null
    }
}
