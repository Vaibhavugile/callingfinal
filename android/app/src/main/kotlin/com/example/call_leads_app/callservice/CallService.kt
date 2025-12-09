package com.example.call_leads_app.callservice

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.database.Cursor
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.CallLog
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import io.flutter.plugin.common.EventChannel
import kotlin.math.abs
import java.util.ArrayDeque
import java.util.concurrent.TimeUnit
import android.app.PendingIntent
import android.content.ComponentName
import com.google.firebase.crashlytics.FirebaseCrashlytics

/**
 * CallService — responsible for tracking call state, persisting events and forwarding to Flutter.
 *
 * Important changes in this edited version:
 *  - Ensures startForeground() is called immediately and defensively to avoid ForegroundServiceDidNotStartInTimeException.
 *  - Adds a small foregroundStarted flag and a defensive attempt in onStartCommand() to guarantee startForeground().
 *  - Uses NotificationCompat for wide compatibility.
 *  - Retains original logic for call handling, call-log reading, queueing, and Crashlytics.
 *
 * Keep the service declared in AndroidManifest with foregroundServiceType as appropriate (phone)
 * and ensure permissions are declared.
 */
class CallService : Service() {

    companion object {
        @Volatile
        var eventSink: EventChannel.EventSink? = null

        // In-memory buffer of events that arrived while Flutter wasn't connected.
        val pendingEvents: ArrayDeque<Map<String, Any?>> = ArrayDeque()

        private const val TAG = "CallService"

        private const val CALL_COOLDOWN_MS = 2000L
        private const val CALL_LOG_DELAY_MS = 800L
        private const val CALL_LOG_RETRY_DELAY_MS = 900L
        private const val CALL_LOG_RETRY_MAX = 6
        private const val OUTGOING_MARKER_WINDOW_MS = 12_000L

        private const val PREFS = "call_leads_prefs"
        private const val KEY_LAST_OUTGOING = "last_outgoing_number"
        private const val KEY_LAST_OUTGOING_TS = "last_outgoing_ts"

        private const val FINAL_LOCK_TTL_MS = 2500L

        private const val NOTIF_CHANNEL_ID = "call_channel"
        private const val NOTIF_CHANNEL_NAME = "Call Tracking"
        private const val NOTIF_ID = 1001

        private const val REUSE_WINDOW_MS = 120_000L
        private const val ACTIVE_CALL_TTL_MS = 60 * 60 * 1000L // 1 hour

        fun flushPendingToSink() {
            try {
                val sink = eventSink
                if (sink == null) {
                    Log.d(TAG, "flushPendingToSink: sink is null; nothing to flush.")
                    return
                }

                synchronized(pendingEvents) {
                    if (pendingEvents.isEmpty()) {
                        Log.d(TAG, "flushPendingToSink: no in-memory pending events.")
                        return
                    }
                    val toFlush = ArrayList<Map<String, Any?>>()
                    while (pendingEvents.isNotEmpty()) {
                        toFlush.add(pendingEvents.removeFirst())
                    }

                    Handler(Looper.getMainLooper()).post {
                        try {
                            toFlush.forEach { ev ->
                                try {
                                    eventSink?.success(ev)
                                } catch (e: Exception) {
                                    FirebaseCrashlytics.getInstance().recordException(e)
                                    Log.e(TAG, "Error while flushing pending event to sink: ${e.localizedMessage}")
                                    synchronized(pendingEvents) { pendingEvents.addFirst(ev) }
                                }
                            }
                        } catch (e: Exception) {
                            FirebaseCrashlytics.getInstance().recordException(e)
                            Log.e(TAG, "Error posting flush to main handler: ${e.localizedMessage}")
                            synchronized(pendingEvents) { toFlush.reversed().forEach { pendingEvents.addFirst(it) } }
                        }
                    }
                }
            } catch (e: Exception) {
                FirebaseCrashlytics.getInstance().recordException(e)
                Log.e(TAG, "flushPendingToSink error: ${e.localizedMessage}", e)
            }
        }
    }

    private lateinit var telephonyManager: TelephonyManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private var currentCallNumber: String? = null
    private var currentCallDirection: String? = null
    private var previousCallState: Int = TelephonyManager.CALL_STATE_IDLE
    private var lastCallEndTime: Long = 0
    private var legacyListener: CallStateListener? = null
    private var modernCallback: TelephonyCallback? = null

    // Defensive flag to indicate whether startForeground has been executed successfully
    @Volatile
    private var foregroundStarted = false

    override fun onCreate() {
        super.onCreate()
        try {
            FirebaseCrashlytics.getInstance().log("CallService.onCreate")
            createNotificationChannelIfNeeded()

            // Immediate minimal foreground notification — MUST be called quickly to avoid system kill on Android 12+
            try {
                startForegroundImmediate()
                foregroundStarted = true
                Log.d(TAG, "✅ Immediate startForeground() called in onCreate")
            } catch (e: Exception) {
                // Record and continue — we will attempt again in onStartCommand() if necessary
                FirebaseCrashlytics.getInstance().recordException(e)
                Log.w(TAG, "startForegroundImmediate failed in onCreate: ${e.localizedMessage}")
            }

            telephonyManager = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
            registerTelephonyCallback()
            Log.d(TAG, "✅ Service created and listening.")
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.e(TAG, "Error in onCreate: ${e.localizedMessage}", e)
        }
    }

    /**
     * Defensive helper that builds a minimal notification and calls startForeground.
     * Kept small and fast.
     */
    private fun startForegroundImmediate() {
        val notif = buildMinimalNotification()
        startForeground(NOTIF_ID, notif)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        FirebaseCrashlytics.getInstance().log("CallService.onStartCommand extras=${intent?.extras}")
        try {
            // Defensive re-check: if for some reason the OS didn't see our startForeground() earlier,
            // attempt to call it again immediately to satisfy the 5s requirement.
            if (!foregroundStarted) {
                try {
                    startForegroundImmediate()
                    foregroundStarted = true
                    Log.d(TAG, "✅ startForeground() re-attempt in onStartCommand succeeded")
                } catch (e: Exception) {
                    FirebaseCrashlytics.getInstance().recordException(e)
                    Log.w(TAG, "startForeground re-attempt failed in onStartCommand: ${e.localizedMessage}")
                }
            }

            Log.d(TAG, "➡️ onStartCommand extras=${intent?.extras}")
            val event = intent?.getStringExtra("event")
            val number = intent?.getStringExtra("phoneNumber")
            val direction = intent?.getStringExtra("direction")
            val callIdFromIntent = intent?.getStringExtra("callId")

            if (event == "ended") {
                Log.d(TAG, "Received 'ended' intent — deferring final result to call log (numberOverride=$number).")
                readCallLogForLastCall(numberOverride = number, directionOverride = null, cooldown = true, retryCount = 0)
                return START_STICKY
            }

            if (!number.isNullOrEmpty() && !direction.isNullOrEmpty()) {
                currentCallNumber = number
                if (currentCallDirection == null || currentCallDirection == "unknown") {
                    currentCallDirection = direction
                } else {
                    if (currentCallDirection != "outbound") {
                        currentCallDirection = direction
                    }
                }

                if (event == "outgoing_start") {
                    val payload = mapOf<String, Any?>(
                        "phoneNumber" to number,
                        "direction" to "outbound",
                        "outcome" to "outgoing_start",
                        "timestamp" to System.currentTimeMillis(),
                        "durationInSeconds" to null,
                        "callId" to callIdFromIntent
                    )
                    Log.d(TAG, "DEBUG: Immediate forward outbound -> $payload")
                    persistAndForwardEvent(payload)
                } else if (event != null && event != "state_change") {
                    sendCallEvent(number, currentCallDirection ?: direction, "answered", System.currentTimeMillis(), null)
                }
            }
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.e(TAG, "Error in onStartCommand: ${e.localizedMessage}", e)
        }
        return START_STICKY
    }

    private fun registerTelephonyCallback() {
        try {
            FirebaseCrashlytics.getInstance().log("CallService.registerTelephonyCallback")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                modernCallback = CallStateCallback(this)
                telephonyManager.registerTelephonyCallback(mainExecutor, modernCallback as CallStateCallback)
                Log.d(TAG, "✅ Registered TelephonyCallback (API S+)")
            } else {
                @Suppress("DEPRECATION")
                legacyListener = CallStateListener(this)
                @Suppress("DEPRECATION")
                telephonyManager.listen(legacyListener, PhoneStateListener.LISTEN_CALL_STATE)
                Log.d(TAG, "✅ Registered PhoneStateListener (API < S)")
            }
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.e(TAG, "Error registering telephony callback: ${e.localizedMessage}", e)
        }
    }

    private fun unregisterTelephonyCallback() {
        try {
            FirebaseCrashlytics.getInstance().log("CallService.unregisterTelephonyCallback")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                modernCallback?.let {
                    telephonyManager.unregisterTelephonyCallback(it)
                    modernCallback = null
                    Log.d(TAG, "✅ Unregistered TelephonyCallback")
                }
            } else {
                @Suppress("DEPRECATION")
                legacyListener?.let {
                    telephonyManager.listen(it, PhoneStateListener.LISTEN_NONE)
                    legacyListener = null
                    Log.d(TAG, "✅ Unregistered PhoneStateListener")
                }
            }
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.e(TAG, "Error unregistering telephony callback: ${e.localizedMessage}", e)
        }
    }

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

    private fun ensureCallIdForPhone(normalizedPhone: String?, prefs: SharedPreferences): String? {
        try {
            if (normalizedPhone.isNullOrEmpty()) return null
            val existing = prefs.getString("callid_$normalizedPhone", null)
            if (!existing.isNullOrEmpty()) {
                val ts = prefs.getLong("callid_ts_$normalizedPhone", 0L)
                if (ts == 0L) prefs.edit().putLong("callid_ts_$normalizedPhone", System.currentTimeMillis()).apply()
                return existing
            }

            val newId = generateCallId()
            markCallActiveForPhone(applicationContext, normalizedPhone, newId)
            Log.d(TAG, "Saved callId marker for $normalizedPhone -> $newId (ensureCallIdForPhone)")
            return newId
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.w(TAG, "ensureCallIdForPhone failed: ${e.localizedMessage}")
        }
        return null
    }

        private fun persistAndForwardEvent(payload: Map<String, Any?>) {
        try {
            FirebaseCrashlytics.getInstance().log("persistAndForwardEvent called for phone=${payload["phoneNumber"]}")
            val mutable = payload.toMutableMap()

            // ----------------------------------------------------
            // Attach tenant + user identity from SharedPreferences
            // ----------------------------------------------------
            try {
                val prefsLocal = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

                // tenantId (business)
                val tenantId = prefsLocal.getString("tenantId", null)
                if (!tenantId.isNullOrEmpty()) {
                    mutable["tenantId"] = tenantId
                    Log.d(TAG, "Attached tenantId=$tenantId to event for phone=${mutable["phoneNumber"]}")
                } else {
                    mutable["needsTenantReview"] = true
                    Log.w(TAG, "No tenantId in prefs – event marked needsTenantReview for phone=${mutable["phoneNumber"]}")
                }

                // ✅ NEW: user identity (who handled this call)
                val userId = prefsLocal.getString("userId", null)
                val userName = prefsLocal.getString("userName", null)

                if (!userId.isNullOrEmpty()) {
                    mutable["handledByUserId"] = userId
                }
                if (!userName.isNullOrEmpty()) {
                    mutable["handledByUserName"] = userName
                }

                Log.d(
                    TAG,
                    "Attached user identity to event: userId=$userId userName=$userName phone=${mutable["phoneNumber"]}"
                )
            } catch (e: Exception) {
                FirebaseCrashlytics.getInstance().recordException(e)
                Log.w(TAG, "Error while reading tenant/user from prefs: ${e.localizedMessage}")
            }

            // ------------------------------
            // CallId resolution / markers
            // ------------------------------
            val phoneRaw = (mutable["phoneNumber"] as? String)
            val normalizedPhone = normalizeNumber(phoneRaw) ?: phoneRaw

            val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

            var callId = mutable["callId"] as? String
            if (callId.isNullOrEmpty()) {
                try {
                    if (!normalizedPhone.isNullOrEmpty()) {
                        val existing = readActiveOrRecentCallId(applicationContext, normalizedPhone)
                        if (!existing.isNullOrEmpty()) {
                            callId = existing
                            mutable["callId"] = callId
                            Log.d(
                                TAG,
                                "Reused existing active/recent callId marker for $normalizedPhone -> $callId (persistAndForwardEvent)"
                            )
                        }
                    }
                } catch (e: Exception) {
                    FirebaseCrashlytics.getInstance().recordException(e)
                    Log.w(TAG, "Error checking existing callId marker: ${e.localizedMessage}")
                }
            }

            if (callId.isNullOrEmpty()) {
                callId = ensureCallIdForPhone(normalizedPhone, prefs) ?: generateCallId()
                mutable["callId"] = callId
                try {
                    val markerKey = if (!normalizedPhone.isNullOrEmpty()) normalizedPhone else (phoneRaw ?: "")
                    if (markerKey.isNotEmpty()) {
                        markCallActiveForPhone(applicationContext, markerKey, callId)
                        Log.d(TAG, "Saved callId marker for $markerKey -> $callId (persistAndForwardEvent)")
                    } else {
                        prefs.edit().putString("callid_to_phone_$callId", phoneRaw).apply()
                        Log.d(TAG, "Saved reverse callId mapping only for callId=$callId")
                    }
                } catch (e: Exception) {
                    FirebaseCrashlytics.getInstance().recordException(e)
                    Log.w(TAG, "Failed saving callId marker in persistAndForwardEvent: ${e.localizedMessage}")
                }
            } else {
                try {
                    val existing = prefs.getString("callid_to_phone_$callId", null)
                    if (existing.isNullOrEmpty() && !normalizedPhone.isNullOrEmpty()) {
                        prefs.edit().putString("callid_to_phone_$callId", normalizedPhone).apply()
                        Log.d(TAG, "Backfilled reverse mapping for callId=$callId -> $normalizedPhone")
                    }
                } catch (e: Exception) {
                    FirebaseCrashlytics.getInstance().recordException(e)
                    Log.w(TAG, "Failed ensuring reverse mapping exists: ${e.localizedMessage}")
                }
            }

            // ------------------------------
            // Queue + worker + notification
            // ------------------------------
            val q = EventQueue(applicationContext)
            q.enqueue(mutable)
            Log.d(TAG, "Persisted event to EventQueue. queueSize=${q.size()} payload=$mutable")
            FirebaseCrashlytics.getInstance().log("Persisted event to EventQueue (phone=${mutable["phoneNumber"]})")

            val workRequest = OneTimeWorkRequestBuilder<UploadWorker>()
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build()
                )
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 10_000L, TimeUnit.MILLISECONDS)
                .build()

            WorkManager.getInstance(applicationContext).enqueue(workRequest)

            try {
                val outcome = (mutable["outcome"] as? String) ?: ""
                val phone = (mutable["phoneNumber"] as? String) ?: ""
                val dir = (mutable["direction"] as? String) ?: ""
                when (outcome) {
                    "outgoing_start" -> {
                        Log.d(TAG, "Updating notification: outgoing_start for $phone")
                        showOrUpdateCallNotification(phone, dir, "Calling…")
                    }
                    "answered", "answered_external", "answered_external" -> {
                        Log.d(TAG, "Updating notification: answered for $phone")
                        showOrUpdateCallNotification(phone, dir, "In call")
                    }
                    "ended", "missed", "rejected" -> {
                        Log.d(TAG, "Updating notification: final outcome $outcome for $phone")
                        showOrUpdateCallNotification(
                            phone,
                            dir,
                            when (outcome) {
                                "missed" -> "Missed"
                                "rejected" -> "Rejected"
                                else -> "Call ended"
                            }
                        )
                        mainHandler.postDelayed({ clearCallNotification() }, 1500)
                    }
                }
            } catch (e: Exception) {
                FirebaseCrashlytics.getInstance().recordException(e)
                Log.w(TAG, "Failed to update notification for event: ${e.localizedMessage}")
            }

            sendToFlutterOrBuffer(mutable)
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.e(TAG, "Error persisting/forwarding event: ${e.localizedMessage}", e)
            try {
                sendToFlutterOrBuffer(payload)
            } catch (ex: Exception) {
                FirebaseCrashlytics.getInstance().recordException(ex)
                Log.e(TAG, "Failed to buffer payload after persist error: ${ex.localizedMessage}", ex)
            }
        }
    }


    private fun sendToFlutterOrBuffer(payload: Map<String, Any?>) {
        try {
            val sink = eventSink
            if (sink == null) {
                Log.w(TAG, "⚠️ Flutter not connected yet → buffering pending event (in-memory)")
                synchronized(pendingEvents) {
                    pendingEvents.addLast(payload)
                    if (pendingEvents.size > 200) pendingEvents.removeFirst()
                }
            } else {
                mainHandler.post {
                    try {
                        eventSink?.success(payload)
                    } catch (e: Exception) {
                        FirebaseCrashlytics.getInstance().recordException(e)
                        Log.e(TAG, "Error sending event to flutter: ${e.localizedMessage}")
                        synchronized(pendingEvents) { pendingEvents.addLast(payload) }
                    }
                }
            }
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.e(TAG, "sendToFlutterOrBuffer error: ${e.localizedMessage}")
            synchronized(pendingEvents) { pendingEvents.addLast(payload) }
        }
    }

    fun handleCallStateUpdate(state: Int, incomingNumber: String?) {
        FirebaseCrashlytics.getInstance().log("handleCallStateUpdate state=${stateToName(state)} incoming=$incomingNumber")
        Log.d(TAG, "📞 Listener State Change: ${stateToName(state)} (Incoming: $incomingNumber)")

        if (state == TelephonyManager.CALL_STATE_IDLE && System.currentTimeMillis() < lastCallEndTime + CALL_COOLDOWN_MS) {
            Log.d(TAG, "🚫 DEDUPLICATED: IDLE event ignored due to cooldown.")
            return
        }

        try {
            if (state == TelephonyManager.CALL_STATE_OFFHOOK && previousCallState == TelephonyManager.CALL_STATE_IDLE && currentCallNumber.isNullOrEmpty()) {
                val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                val lastOutgoing = prefs.getString(KEY_LAST_OUTGOING, null)
                val lastTs = prefs.getLong(KEY_LAST_OUTGOING_TS, 0L)
                val now = System.currentTimeMillis()
                if (!lastOutgoing.isNullOrEmpty() && now - lastTs <= OUTGOING_MARKER_WINDOW_MS) {
                    if (numbersLikelyMatch(lastOutgoing, incomingNumber) || incomingNumber == null) {
                        currentCallNumber = lastOutgoing
                        currentCallDirection = "outbound"
                        Log.d(TAG, "EARLY: Detected outgoing marker → treating call as OUTBOUND for $currentCallNumber")
                        prefs.edit().remove(KEY_LAST_OUTGOING).remove(KEY_LAST_OUTGOING_TS).apply()

                        sendCallEvent(currentCallNumber ?: "unknown", "outbound", "answered", System.currentTimeMillis(), null)
                        previousCallState = state
                        return
                    }
                }
            }
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.e(TAG, "Error reading outgoing marker early: ${e.localizedMessage}", e)
        }

        when (state) {
            TelephonyManager.CALL_STATE_OFFHOOK -> {
                if (previousCallState == TelephonyManager.CALL_STATE_RINGING) {
                    val dir = if (currentCallDirection == "outbound") "outbound" else "inbound"
                    sendCallEvent(currentCallNumber ?: incomingNumber ?: "unknown", currentCallDirection ?: dir, "answered", System.currentTimeMillis(), null)
                } else if (previousCallState == TelephonyManager.CALL_STATE_IDLE) {
                    if (currentCallNumber.isNullOrEmpty()) {
                        readCallLogForLastCall()
                    } else {
                        sendCallEvent(currentCallNumber!!, currentCallDirection ?: "outbound", "answered", System.currentTimeMillis(), null)
                    }
                }
            }

            TelephonyManager.CALL_STATE_IDLE -> {
                if (previousCallState == TelephonyManager.CALL_STATE_OFFHOOK) {
                    handleCallEndedAfterOffhook()
                } else if (previousCallState == TelephonyManager.CALL_STATE_RINGING) {
                    handleCallEndedAfterRinging(incomingNumber)
                }
                currentCallNumber = null
                currentCallDirection = null
                lastCallEndTime = System.currentTimeMillis()
            }

            TelephonyManager.CALL_STATE_RINGING -> {
                Log.d(TAG, "RINGING event via listener.")
                if (currentCallDirection == null) currentCallDirection = "inbound"
                if (currentCallNumber == null && !incomingNumber.isNullOrEmpty()) currentCallNumber = incomingNumber
            }
        }

        previousCallState = state
    }

    private fun handleCallEndedAfterOffhook() {
        if (currentCallNumber.isNullOrEmpty()) {
            Log.e(TAG, "❌ Call ended (OFFHOOK->IDLE) but currentCallNumber is missing.")
            return
        }
        readCallLogForLastCall(numberOverride = currentCallNumber, directionOverride = currentCallDirection, cooldown = true, retryCount = 0)
    }

    private fun handleCallEndedAfterRinging(incomingNumber: String?) {
        val finalNumber = currentCallNumber ?: incomingNumber
        if (finalNumber.isNullOrEmpty()) {
            Log.e(TAG, "❌ Call ended (RINGING->IDLE) but no number available.")
            return
        }
        readCallLogForLastCall(numberOverride = finalNumber, directionOverride = "inbound", cooldown = true, retryCount = 0)
    }

    private fun readCallLogForLastCall(
        numberOverride: String? = null,
        directionOverride: String? = null,
        cooldown: Boolean = false,
        retryCount: Int = 0
    ) {
        FirebaseCrashlytics.getInstance().log("readCallLogForLastCall start numberOverride=$numberOverride directionOverride=$directionOverride retry=$retryCount")
        if (checkSelfPermission(android.Manifest.permission.READ_CALL_LOG) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            FirebaseCrashlytics.getInstance().log("READ_CALL_LOG permission not granted; using fallback if available")
            Log.e(TAG, "❌ READ_CALL_LOG permission not granted for failsafe.")
            val outgoing = getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_LAST_OUTGOING, null)
            val fallbackNumber = numberOverride ?: outgoing
            if (!fallbackNumber.isNullOrEmpty()) {
                val ts = getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong(KEY_LAST_OUTGOING_TS, System.currentTimeMillis())
                emitFinalCallEventIfNotLocked(fallbackNumber, "ended", ts, null, directionOverride)
            } else {
                Log.w(TAG, "No fallback due to missing number and missing permission.")
            }
            return
        }

        val delay = if (cooldown) CALL_LOG_DELAY_MS else 0L
        mainHandler.postDelayed({
            var cursor: Cursor? = null
            try {
                val recentWindowMs = System.currentTimeMillis() - 5 * 60 * 1000L
                val selection = "${CallLog.Calls.DATE}>=?"
                val selectionArgs = arrayOf(recentWindowMs.toString())
                val limitUri = CallLog.Calls.CONTENT_URI.buildUpon().appendQueryParameter("limit", "20").build()

                cursor = try {
                    contentResolver.query(
                        limitUri,
                        arrayOf(CallLog.Calls._ID, CallLog.Calls.NUMBER, CallLog.Calls.TYPE, CallLog.Calls.DATE, CallLog.Calls.DURATION),
                        selection,
                        selectionArgs,
                        "${CallLog.Calls.DATE} DESC"
                    )
                } catch (e: Exception) {
                    FirebaseCrashlytics.getInstance().recordException(e)
                    Log.w(TAG, "CallLog query threw exception: ${e.localizedMessage}")
                    null
                }

                if (cursor == null || cursor.count == 0) {
                    Log.w(TAG, "Call log query returned empty or null.")
                    if (retryCount < CALL_LOG_RETRY_MAX - 1) {
                        Log.d(TAG, "Retrying call-log read after short delay. retry=${retryCount + 1}")
                        mainHandler.postDelayed({
                            readCallLogForLastCall(numberOverride, directionOverride, cooldown, retryCount + 1)
                        }, CALL_LOG_RETRY_DELAY_MS)
                    } else {
                        Log.w(TAG, "Max retries reached and no usable rows. Attempting fallback if possible.")
                        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                        val outgoing = prefs.getString(KEY_LAST_OUTGOING, null)
                        val fallbackNumber = numberOverride ?: outgoing
                        if (!fallbackNumber.isNullOrEmpty()) {
                            val ts = prefs.getLong(KEY_LAST_OUTGOING_TS, System.currentTimeMillis())
                            emitFinalCallEventIfNotLocked(fallbackNumber, "ended", ts, null, directionOverride)
                        } else {
                            Log.w(TAG, "No number available to emit final; skipping fallback.")
                        }
                    }
                    return@postDelayed
                }

                val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                val lastOutgoing = prefs.getString(KEY_LAST_OUTGOING, null)
                val lastOutgoingTs = prefs.getLong(KEY_LAST_OUTGOING_TS, 0L)
                val outgoingMarker: Pair<String, Long>? = if (!lastOutgoing.isNullOrEmpty() && lastOutgoingTs > 0L) Pair(lastOutgoing, lastOutgoingTs) else null

                val best = pickBestCallLogRow(cursor, outgoingMarker)
                if (best != null) {
                    val num = numberOverride ?: best.number ?: outgoingMarker?.first ?: ""
                    val ts = best.timestamp
                    val dur = if (best.duration >= 0) best.duration else null
                    val outcomeAndDir = getOutcomeAndDirectionFromType(best.type, directionOverride)
                    val outcome = outcomeAndDir.first
                    var direction = outcomeAndDir.second

                    if (outgoingMarker != null && numbersLikelyMatch(outgoingMarker.first, num) && abs(outgoingMarker.second - ts) <= OUTGOING_MARKER_WINDOW_MS) {
                        direction = "outbound"
                    }

                    Log.w(TAG, "🚨 Call Log Result (picked): $outcome ($direction) to $num, Duration: $dur ts:$ts")
                    FirebaseCrashlytics.getInstance().log("CallLog picked: outcome=$outcome direction=$direction num=$num dur=$dur")
                    emitFinalCallEventIfNotLocked(num, outcome, ts, dur, direction)
                } else {
                    Log.w(TAG, "No suitable call-log row found after retries.")
                    val outgoing = prefs.getString(KEY_LAST_OUTGOING, null)
                    val fallbackNumber = numberOverride ?: outgoing
                    if (!fallbackNumber.isNullOrEmpty()) {
                        val ts = prefs.getLong(KEY_LAST_OUTGOING_TS, System.currentTimeMillis())
                        emitFinalCallEventIfNotLocked(fallbackNumber, "ended", ts, null, directionOverride)
                    } else {
                        Log.w(TAG, "No number available to emit final; skipping fallback.")
                    }
                }
            } catch (e: Exception) {
                FirebaseCrashlytics.getInstance().recordException(e)
                Log.e(TAG, "❌ Error reading Call Log: ${e.localizedMessage}", e)
                val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                val outgoing = prefs.getString(KEY_LAST_OUTGOING, null)
                val fallbackNumber = numberOverride ?: outgoing
                if (!fallbackNumber.isNullOrEmpty()) {
                    val ts = prefs.getLong(KEY_LAST_OUTGOING_TS, System.currentTimeMillis())
                    emitFinalCallEventIfNotLocked(fallbackNumber, "ended", ts, null, directionOverride)
                } else {
                    Log.w(TAG, "No number available to emit final after error; skipping fallback.")
                }
            } finally {
                try {
                    cursor?.close()
                } catch (e: Exception) {
                    FirebaseCrashlytics.getInstance().recordException(e)
                    Log.w(TAG, "Failed to close call log cursor: ${e.localizedMessage}")
                }
            }
        }, delay)
    }

    private data class _RowPick(val number: String?, val type: Int, val timestamp: Long, val duration: Int)

    private fun pickBestCallLogRow(cursor: Cursor, outgoingMarker: Pair<String, Long>?): _RowPick? {
        val rows = mutableListOf<_RowPick>()
        if (!cursor.moveToFirst()) return null
        do {
            try {
                val number = cursor.getString(cursor.getColumnIndexOrThrow(CallLog.Calls.NUMBER))
                val type = cursor.getInt(cursor.getColumnIndexOrThrow(CallLog.Calls.TYPE))
                val ts = cursor.getLong(cursor.getColumnIndexOrThrow(CallLog.Calls.DATE))
                val dur = cursor.getInt(cursor.getColumnIndexOrThrow(CallLog.Calls.DURATION))
                rows.add(_RowPick(number, type, ts, dur))
            } catch (e: Exception) {
                FirebaseCrashlytics.getInstance().recordException(e)
            }
        } while (cursor.moveToNext())

        if (rows.isEmpty()) return null

        outgoingMarker?.let { (markerNumber, markerTs) ->
            val tol = OUTGOING_MARKER_WINDOW_MS
            val matches = rows.filter { it.number != null && numbersLikelyMatch(it.number, markerNumber) && abs(it.timestamp - markerTs) <= tol }
            if (matches.isNotEmpty()) return matches.maxByOrNull { it.duration }
        }

        val withDur = rows.filter { it.duration > 0 }
        if (withDur.isNotEmpty()) return withDur.maxByOrNull { it.duration }
        return rows.maxByOrNull { it.timestamp }
    }

    private fun getOutcomeAndDirectionFromType(callType: Int, directionOverride: String? = null): Pair<String, String> {
        return when (callType) {
            CallLog.Calls.INCOMING_TYPE -> Pair("ended", "inbound")
            CallLog.Calls.OUTGOING_TYPE -> Pair("outgoing_start", "outbound")
            CallLog.Calls.MISSED_TYPE -> Pair("missed", "inbound")
            CallLog.Calls.VOICEMAIL_TYPE -> Pair("voicemail", "inbound")
            5 -> Pair("rejected", "inbound")
            CallLog.Calls.ANSWERED_EXTERNALLY_TYPE -> Pair("answered_external", "inbound")
            else -> {
                if (!directionOverride.isNullOrEmpty()) {
                    val out = if (directionOverride == "outbound") "outgoing_start" else "ended"
                    Pair(out, directionOverride)
                } else {
                    Pair("ended", "inbound")
                }
            }
        }
    }

    private fun emitFinalCallEventIfNotLocked(phoneNumber: String, finalOutcome: String, timestampMs: Long, durationSec: Int?, directionOverride: String? = null) {
        val normalized = normalizeNumber(phoneNumber) ?: ""
        if (normalized.isEmpty()) {
            Log.w(TAG, "emitFinalCallEventIfNotLocked: normalized phone empty → skipping.")
            return
        }
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val lockKey = "final_lock_$normalized"
        val lockedUntil = prefs.getLong(lockKey, 0L)
        val now = System.currentTimeMillis()

        if (now < lockedUntil) {
            Log.d(TAG, "Finalization for $normalized currently locked until $lockedUntil — skipping.")
            return
        }

        if (durationSec != null) {
            prefs.edit().putLong(lockKey, now + FINAL_LOCK_TTL_MS).apply()
            Log.d(TAG, "Placed finalization lock for $normalized until ${now + FINAL_LOCK_TTL_MS}")
        } else {
            prefs.edit().remove(lockKey).apply()
        }

        emitFinalCallEvent(phoneNumber, finalOutcome, timestampMs, durationSec, directionOverride)
    }

    private fun emitFinalCallEvent(phoneNumber: String, finalOutcome: String, timestampMs: Long, durationSec: Int?, directionOverride: String? = null) {
        val normalized = normalizeNumber(phoneNumber) ?: ""
        if (normalized.isEmpty()) {
            Log.w(TAG, "emitFinalCallEvent: empty phoneNumber — skipping emit.")
            return
        }

        val outgoingMarker = readOutgoingMarker()
        val isOutbound = if (directionOverride != null) {
            directionOverride == "outbound"
        } else {
            outgoingMarker?.first?.let { numbersLikelyMatch(it, phoneNumber) } ?: false
        }

        val lastFinalKey = "last_final_ts_$normalized"
        val lastFinalTs = getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong(lastFinalKey, 0L)
        val lastDurKey = "last_final_dur_$normalized"
        val lastDur = getSharedPreferences(PREFS, Context.MODE_PRIVATE).getInt(lastDurKey, -1)

        if (lastFinalTs != 0L && abs(lastFinalTs - timestampMs) < 2000L) {
            if (durationSec == null || durationSec == lastDur) {
                Log.d(TAG, "Skipping duplicate final event for $normalized (ts close and dur unchanged)")
                return
            }
        }

        val payload = mapOf(
            "phoneNumber" to phoneNumber,
            "direction" to if (isOutbound) "outbound" else "inbound",
            "outcome" to finalOutcome,
            "timestamp" to timestampMs,
            "durationInSeconds" to durationSec
        )

        Log.d(TAG, "📤 Emitting final event: $payload")
        FirebaseCrashlytics.getInstance().log("Emitting final event payload for $normalized outcome=$finalOutcome duration=$durationSec")
        persistAndForwardEvent(payload)

        getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putLong(lastFinalKey, timestampMs).putInt(lastDurKey, durationSec ?: -1).apply()

        try {
            clearCallIdMapping(applicationContext, phoneNumber)
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.w(TAG, "Failed to clear callId mapping after finalization: ${e.localizedMessage}")
        }
    }

    fun sendCallEvent(number: String, direction: String, outcome: String, timestamp: Long, durationInSeconds: Int?) {
        val data = mapOf(
            "phoneNumber" to number,
            "direction" to direction,
            "outcome" to outcome,
            "timestamp" to timestamp,
            "durationInSeconds" to durationInSeconds,
        )
        Log.d(TAG, "📤 Sending event to Flutter (and persisting): $data")
        FirebaseCrashlytics.getInstance().log("sendCallEvent for phone=${number} outcome=${outcome}")
        persistAndForwardEvent(data)
    }

    private fun readOutgoingMarker(): Pair<String, Long>? {
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val num = prefs.getString(KEY_LAST_OUTGOING, null)
        val ts = prefs.getLong(KEY_LAST_OUTGOING_TS, 0L)
        if (num == null || ts == 0L) return null
        return Pair(num, ts)
    }

    // Build a minimal notification used immediately at service start
    private fun buildMinimalNotification(): Notification {
        val title = "Call tracking"
        val content = "Preparing…"

        val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pending = if (launch != null) PendingIntent.getActivity(this, 0, launch, pendingFlags) else null

        return NotificationCompat.Builder(this, NOTIF_CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(content)
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setOngoing(true)
            .setContentIntent(pending)
            .build()
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, NOTIF_CHANNEL_ID)
            .setContentTitle("Call Tracking Running")
            .setContentText("Detecting call events")
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setOngoing(true)
            .build()
    }

    private fun createNotificationChannelIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                val channel = NotificationChannel(NOTIF_CHANNEL_ID, NOTIF_CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW)
                channel.setShowBadge(false)
                val nm = getSystemService(NotificationManager::class.java)
                nm.createNotificationChannel(channel)
            } catch (e: Exception) {
                FirebaseCrashlytics.getInstance().recordException(e)
                Log.e(TAG, "Error creating notification channel: ${e.localizedMessage}")
            }
        }
    }

    private fun showOrUpdateCallNotification(phone: String, direction: String, statusText: String) {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val title = when (direction) {
                "outbound", "outgoing" -> "Outgoing: $phone"
                "inbound", "incoming" -> "Incoming: $phone"
                else -> phone
            }
            val content = statusText

            val targetIntent = Intent(this, com.example.call_leads_app.MainActivity::class.java).apply {
                putExtra("open_lead_phone", phone)
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_NEW_TASK
            }

            val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }

            val pending = PendingIntent.getActivity(this, /*requestCode=*/ phone.hashCode(), targetIntent, pendingFlags)

            val notif = NotificationCompat.Builder(this, NOTIF_CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(content)
                .setSmallIcon(android.R.drawable.sym_call_outgoing)
                .setContentIntent(pending)
                .setAutoCancel(true)
                .setOngoing(true)
                .build()

            nm.notify(NOTIF_ID, notif)
            Log.d(TAG, "Notification shown/updated: $title — $content (tap opens MainActivity with phone)")
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.w(TAG, "showOrUpdateCallNotification failed: ${e.localizedMessage}")
        }
    }

    private fun clearCallNotification() {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(NOTIF_ID)
            try {
                // keep the minimal foreground notification running so the service isn't considered background
                startForeground(NOTIF_ID, buildNotification())
            } catch (e: Exception) {
                FirebaseCrashlytics.getInstance().recordException(e)
                Log.w(TAG, "Failed to restart foreground after clearing: ${e.localizedMessage}")
            }
            Log.d(TAG, "Cleared call notification")
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.w(TAG, "clearCallNotification failed: ${e.localizedMessage}")
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        try {
            FirebaseCrashlytics.getInstance().log("CallService.onDestroy")
            unregisterTelephonyCallback()
        } catch (e: Exception) {
            FirebaseCrashlytics.getInstance().recordException(e)
            Log.w(TAG, "Error during onDestroy: ${e.localizedMessage}")
        } finally {
            super.onDestroy()
            Log.d(TAG, "🛑 Service destroyed")
        }
    }

    private fun stateToName(state: Int): String {
        return when (state) {
            TelephonyManager.CALL_STATE_IDLE -> "IDLE"
            TelephonyManager.CALL_STATE_RINGING -> "RINGING"
            TelephonyManager.CALL_STATE_OFFHOOK -> "OFFHOOK"
            else -> "UNKNOWN ($state)"
        }
    }

    private fun generateCallId(): String {
        return "call_" + java.util.UUID.randomUUID().toString().replace("-", "").take(12)
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

            val activeUntil = prefs.getLong("callid_active_until_$normalized", 0L)
            if (activeUntil > now) {
                Log.d(TAG, "Reusing ACTIVE callId for $normalized -> $id (activeUntil=$activeUntil)")
                FirebaseCrashlytics.getInstance().log("Reusing ACTIVE callId for $normalized")
                return id
            }

            val ts = prefs.getLong("callid_ts_$normalized", 0L)
            if (ts != 0L && (now - ts) <= REUSE_WINDOW_MS) {
                Log.d(TAG, "Reusing RECENT callId for $normalized -> $id (ts=$ts)")
                FirebaseCrashlytics.getInstance().log("Reusing RECENT callId for $normalized")
                return id
            }

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
}
