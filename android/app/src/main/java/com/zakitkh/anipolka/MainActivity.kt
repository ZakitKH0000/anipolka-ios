package com.zakitkh.anipolka

import android.app.Application
import android.app.KeyguardManager
import android.content.Intent
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.view.WindowManager
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.lifecycle.lifecycleScope
import com.zakitkh.anipolka.core.ReleasePlanner
import com.zakitkh.anipolka.data.Integrations
import com.zakitkh.anipolka.data.NetworkService
import com.zakitkh.anipolka.data.Notifications
import com.zakitkh.anipolka.data.ShelfAssistant
import com.zakitkh.anipolka.data.ShelfStore
import com.zakitkh.anipolka.ui.AppLockControl
import com.zakitkh.anipolka.ui.AppRequest
import com.zakitkh.anipolka.ui.AppRoot
import com.zakitkh.anipolka.ui.LocalAppLock
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.time.Instant
import java.util.UUID

class AniPolkaApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        Notifications.createChannels(this)
        val store = ShelfStore.get(this)
        Integrations.update(this, store.current)
    }
}

class MainActivity : ComponentActivity() {
    private val requests = MutableStateFlow<AppRequest?>(null)
    private val locked = MutableStateFlow(false)
    private var authenticating = false

    private val lockControl = object : AppLockControl {
        override val available: Boolean get() = canAuthenticate()
        override fun authenticate(reason: String, onResult: (Boolean) -> Unit) = prompt(reason, onResult)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        val store = ShelfStore.get(this)
        val network = NetworkService.get(this)
        val assistant = ShelfAssistant.get(this)
        locked.value = store.current.preferences.appLock
        handle(intent)
        setContent {
            val snapshot by store.snapshot.collectAsState()
            val isLocked by locked.collectAsState()
            val connected by network.connected.collectAsState()
            LaunchedEffect(snapshot.preferences.wifiOnly, connected) { network.wifiOnly = snapshot.preferences.wifiOnly; assistant.queueCovers() }
            LaunchedEffect(snapshot.preferences.appLock) {
                // Also hides the collection in the recent apps screen while the lock is on.
                if (snapshot.preferences.appLock) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE) else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
            LaunchedEffect(snapshot.entries.map { "${it.id}${it.title}${it.coverURL}${it.coverData != null}${it.coverLookupDisabled}" }) { assistant.queueCovers() }
            // Broadcast times: on start, when the connection returns and when a title gets its catalogue ID.
            LaunchedEffect(connected, snapshot.preferences.catalogUpdates, snapshot.entries.map { it.sourceID }) { assistant.refreshAiring() }
            CompositionLocalProvider(LocalAppLock provides lockControl) {
                AppRoot(requests, isLocked) { if (!authenticating) prompt("Открыть коллекцию АниПолки") { ok -> if (ok) locked.value = false } }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    override fun onStart() {
        super.onStart()
        val store = ShelfStore.get(this)
        val due = store.current.entries.any { e -> e.subscriptions.any { it.enabled && Instant.now().epochSecond - (it.lastCheckedAt?.epochSecond ?: 0) > 3600 } }
        if (due) lifecycleScope.launch { ShelfAssistant.get(this@MainActivity).checkReleases(background = true) }
    }

    override fun onStop() {
        super.onStop()
        if (ShelfStore.get(this).current.preferences.appLock && !authenticating && !isChangingConfigurations) locked.value = true
    }

    private fun handle(intent: Intent?) {
        intent ?: return
        intent.getStringExtra(EXTRA_ENTRY)?.let { raw -> runCatching { UUID.fromString(raw) }.getOrNull()?.let { requests.value = AppRequest.OpenEntry(it) } }
        when (intent.action) {
            ACTION_ADD -> requests.value = AppRequest.Add
            ACTION_MARK_LATEST -> {
                val store = ShelfStore.get(this)
                val entry = ReleasePlanner.continuing(store.current.entries, 1).firstOrNull()
                val updated = entry?.let { store.increment(it.id) }
                Toast.makeText(this, updated?.let { "«${it.title}»: отмечена серия ${it.episode}" } ?: "Нет историй со статусом «Смотрю».", Toast.LENGTH_SHORT).show()
            }
            Intent.ACTION_SEND -> {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return
                val url = Regex("https?://\\S+").find(text)?.value ?: return
                requests.value = AppRequest.SharedLink(url)
            }
        }
        intent.removeExtra(EXTRA_ENTRY); intent.action = null
    }

    private fun canAuthenticate(): Boolean = when {
        Build.VERSION.SDK_INT >= 30 -> getSystemService(BiometricManager::class.java)
            .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.DEVICE_CREDENTIAL) == BiometricManager.BIOMETRIC_SUCCESS
        Build.VERSION.SDK_INT >= 28 -> getSystemService(KeyguardManager::class.java).isDeviceSecure
        else -> false
    }

    /** Fingerprint or face with the device PIN as fallback. Without a screen lock nothing can be protected. */
    private fun prompt(reason: String, onResult: (Boolean) -> Unit) {
        if (!canAuthenticate()) { locked.value = false; onResult(true); return }
        authenticating = true
        val builder = BiometricPrompt.Builder(this).setTitle("АниПолка").setSubtitle(reason)
        if (Build.VERSION.SDK_INT >= 30) builder.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.DEVICE_CREDENTIAL)
        else @Suppress("DEPRECATION") builder.setDeviceCredentialAllowed(true)
        builder.build().authenticate(CancellationSignal(), mainExecutor, object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) { authenticating = false; onResult(true) }
            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) { authenticating = false; onResult(false) }
        })
    }

    companion object {
        const val EXTRA_ENTRY = "com.zakitkh.anipolka.ENTRY"
        const val ACTION_ADD = "com.zakitkh.anipolka.ADD"
        const val ACTION_MARK_LATEST = "com.zakitkh.anipolka.MARK_LATEST"
    }
}
