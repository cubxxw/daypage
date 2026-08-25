package app.daypage.android.auth

import android.net.Uri
import app.daypage.android.sync.SyncRequestScheduler
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.Instant
import java.util.Base64
import java.util.UUID

class AuthRepository(
    private val config: DayPageCloudConfig,
    private val httpClient: OkHttpClient,
    private val secureStore: SecureStore,
    private val syncScheduler: SyncRequestScheduler,
) {
    private val refreshMutex = Mutex()
    private val _state = MutableStateFlow<AccountState>(restoreSession()?.let {
        AccountState.BoundAndSyncing(it.account)
    } ?: AccountState.LocalOnly)
    val state: StateFlow<AccountState> = _state.asStateFlow()

    init {
        if (restoreSession() != null) syncScheduler.requestSync()
    }

    fun appleAuthorizationUrl(): String {
        ensureConfigured()
        _state.value = AccountState.Authenticating
        val attempt = newAttempt("apple")
        saveAttempt(attempt)
        return "${config.supabaseUrl}/auth/v1/authorize".toHttpUrl().newBuilder()
            .addQueryParameter("provider", "apple")
            .addQueryParameter("redirect_to", config.redirectUri)
            .addQueryParameter("code_challenge", attempt.challenge)
            .addQueryParameter("code_challenge_method", "S256")
            .addQueryParameter("state", attempt.state)
            .build()
            .toString()
    }

    suspend fun sendEmailLink(rawEmail: String) {
        ensureConfigured()
        val email = rawEmail.trim()
        require(EMAIL.matches(email)) { "Enter a valid email address" }
        _state.value = AccountState.Authenticating
        val attempt = newAttempt("email")
        saveAttempt(attempt)
        runCatching {
            val body = JSONObject()
                .put("email", email)
                .put("create_user", true)
                .put("code_challenge", attempt.challenge)
                .put("code_challenge_method", "S256")
            executeJson(
                request = Request.Builder()
                    .url(
                        "${config.supabaseUrl}/auth/v1/otp".toHttpUrl().newBuilder()
                            .addQueryParameter("redirect_to", config.redirectUri)
                            .build(),
                    )
                    .post(body.toString().jsonBody())
                    .cloudHeaders()
                    .build(),
                allowEmpty = true,
            )
        }.onFailure { error ->
            secureStore.remove(AUTH_ATTEMPT_KEY)
            _state.value = AccountState.ActionRequired(error.userMessage())
            throw error
        }
    }

    suspend fun handleCallback(uri: Uri) {
        if (uri.scheme != "daypage" || uri.host != "auth" || uri.path != "/callback") return
        val callbackError = uri.getQueryParameter("error_description")
            ?: uri.getQueryParameter("error")
        if (!callbackError.isNullOrBlank()) {
            secureStore.remove(AUTH_ATTEMPT_KEY)
            _state.value = AccountState.ActionRequired(callbackError)
            return
        }
        val attempt = restoreAttempt()
        if (attempt == null) {
            _state.value = AccountState.ActionRequired("The sign-in request expired. Please try again.")
            return
        }
        val callbackState = uri.getQueryParameter("state")
        if (callbackState != null && callbackState != attempt.state) {
            secureStore.remove(AUTH_ATTEMPT_KEY)
            _state.value = AccountState.ActionRequired("The sign-in response could not be verified.")
            return
        }
        val code = uri.getQueryParameter("code")
        if (code.isNullOrBlank()) {
            _state.value = AccountState.ActionRequired("The sign-in response did not include an authorization code.")
            return
        }

        _state.value = AccountState.Authenticating
        runCatching { exchangeCode(code, attempt.verifier) }
            .onSuccess { session ->
                saveSession(session)
                secureStore.remove(AUTH_ATTEMPT_KEY)
                _state.value = AccountState.BoundAndSyncing(session.account)
                syncScheduler.requestExpeditedSync()
            }
            .onFailure { error ->
                _state.value = AccountState.ActionRequired(error.userMessage())
            }
    }

    suspend fun accessToken(): String = refreshMutex.withLock {
        val session = restoreSession() ?: throw AuthException("Sign in is required.")
        if (session.expiresAtEpochSeconds > Instant.now().epochSecond + 60) {
            return@withLock session.accessToken
        }
        val refreshed = refresh(session.refreshToken)
        saveSession(refreshed)
        refreshed.accessToken
    }

    fun currentAccount(): AccountIdentity? = restoreSession()?.account

    suspend fun signOutThisDevice() {
        val session = restoreSession()
        if (session != null && config.isConfigured) {
            runCatching {
                executeJson(
                    request = Request.Builder()
                        .url("${config.supabaseUrl}/auth/v1/logout?scope=local")
                        .post(ByteArray(0).toRequestBody(null))
                        .cloudHeaders(session.accessToken)
                        .build(),
                    allowEmpty = true,
                )
            }
        }
        secureStore.remove(SESSION_KEY)
        secureStore.remove(AUTH_ATTEMPT_KEY)
        _state.value = AccountState.LocalOnly
    }

    fun markSynced() {
        val account = restoreSession()?.account ?: return
        _state.value = AccountState.Synced(account)
    }

    fun markSyncActionRequired(message: String) {
        _state.value = AccountState.ActionRequired(message, restoreSession()?.account)
    }

    private suspend fun exchangeCode(code: String, verifier: String): UserSession {
        val body = JSONObject().put("auth_code", code).put("code_verifier", verifier)
        val response = executeJson(
            Request.Builder()
                .url("${config.supabaseUrl}/auth/v1/token?grant_type=pkce")
                .post(body.toString().jsonBody())
                .cloudHeaders()
                .build(),
        )
        return response.asSession()
    }

    private suspend fun refresh(refreshToken: String): UserSession {
        val body = JSONObject().put("refresh_token", refreshToken)
        val response = executeJson(
            Request.Builder()
                .url("${config.supabaseUrl}/auth/v1/token?grant_type=refresh_token")
                .post(body.toString().jsonBody())
                .cloudHeaders()
                .build(),
        )
        return response.asSession()
    }

    private suspend fun executeJson(request: Request, allowEmpty: Boolean = false): JSONObject =
        withContext(Dispatchers.IO) {
            httpClient.newCall(request).execute().use { response ->
                val text = response.body.string()
                if (!response.isSuccessful) {
                    val message = runCatching { JSONObject(text).optString("msg") }
                        .getOrNull()
                        ?.takeIf(String::isNotBlank)
                        ?: "Cloud request failed (${response.code})."
                    throw AuthException(message)
                }
                if (text.isBlank() && allowEmpty) JSONObject() else JSONObject(text)
            }
        }

    private fun Request.Builder.cloudHeaders(accessToken: String? = null): Request.Builder =
        header("apikey", config.anonKey)
            .header("Content-Type", "application/json")
            .header("Accept", "application/json")
            .apply { if (accessToken != null) header("Authorization", "Bearer $accessToken") }

    private fun JSONObject.asSession(): UserSession {
        val user = getJSONObject("user")
        return UserSession(
            accessToken = getString("access_token"),
            refreshToken = getString("refresh_token"),
            expiresAtEpochSeconds = optLong("expires_at").takeIf { it > 0 }
                ?: (Instant.now().epochSecond + getLong("expires_in")),
            account = AccountIdentity(
                userId = user.getString("id"),
                email = user.optString("email").takeIf(String::isNotBlank),
            ),
        )
    }

    private fun saveSession(session: UserSession) {
        secureStore.put(
            SESSION_KEY,
            JSONObject()
                .put("access_token", session.accessToken)
                .put("refresh_token", session.refreshToken)
                .put("expires_at", session.expiresAtEpochSeconds)
                .put("user_id", session.account.userId)
                .put("email", session.account.email ?: JSONObject.NULL)
                .toString(),
        )
    }

    private fun restoreSession(): UserSession? = secureStore.get(SESSION_KEY)?.let { encoded ->
        runCatching {
            val json = JSONObject(encoded)
            UserSession(
                accessToken = json.getString("access_token"),
                refreshToken = json.getString("refresh_token"),
                expiresAtEpochSeconds = json.getLong("expires_at"),
                account = AccountIdentity(
                    userId = json.getString("user_id"),
                    email = if (json.isNull("email")) null else json.getString("email"),
                ),
            )
        }.getOrNull()
    }

    private fun newAttempt(provider: String): AuthAttempt {
        val verifier = randomUrlSafe(64)
        val challenge = Base64.getUrlEncoder().withoutPadding().encodeToString(
            MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()),
        )
        return AuthAttempt(
            provider = provider,
            verifier = verifier,
            challenge = challenge,
            state = UUID.randomUUID().toString(),
            createdAtEpochSeconds = Instant.now().epochSecond,
        )
    }

    private fun saveAttempt(attempt: AuthAttempt) {
        secureStore.put(
            AUTH_ATTEMPT_KEY,
            JSONObject()
                .put("provider", attempt.provider)
                .put("verifier", attempt.verifier)
                .put("challenge", attempt.challenge)
                .put("state", attempt.state)
                .put("created_at", attempt.createdAtEpochSeconds)
                .toString(),
        )
    }

    private fun restoreAttempt(): AuthAttempt? = secureStore.get(AUTH_ATTEMPT_KEY)?.let { encoded ->
        runCatching {
            val json = JSONObject(encoded)
            AuthAttempt(
                provider = json.getString("provider"),
                verifier = json.getString("verifier"),
                challenge = json.getString("challenge"),
                state = json.getString("state"),
                createdAtEpochSeconds = json.getLong("created_at"),
            )
        }.getOrNull()?.takeIf { Instant.now().epochSecond - it.createdAtEpochSeconds < 900 }
    }

    private fun randomUrlSafe(byteCount: Int): String {
        val bytes = ByteArray(byteCount).also(SecureRandom()::nextBytes)
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }

    private fun ensureConfigured() {
        if (!config.isConfigured) throw AuthException("Cloud sign-in is not configured in this build.")
    }

    private fun String.jsonBody() = toRequestBody("application/json".toMediaType())

    private data class AuthAttempt(
        val provider: String,
        val verifier: String,
        val challenge: String,
        val state: String,
        val createdAtEpochSeconds: Long,
    )

    private companion object {
        const val SESSION_KEY = "supabase_session_v1"
        const val AUTH_ATTEMPT_KEY = "pkce_attempt_v1"
        val EMAIL = Regex("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$")
    }
}

class AuthException(message: String) : Exception(message)

private fun Throwable.userMessage(): String = message?.takeIf(String::isNotBlank)
    ?: "Something went wrong. Please try again."
