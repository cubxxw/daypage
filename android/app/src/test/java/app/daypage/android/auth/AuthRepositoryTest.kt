package app.daypage.android.auth

import android.app.Application
import android.net.Uri
import app.daypage.android.sync.SyncRequestScheduler
import kotlinx.coroutines.test.runTest
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class AuthRepositoryTest {
    @Test
    fun emailMagicLinkCarriesPkceAndReturnsToAndroidCallback() = runTest {
        val transport = RecordingTransport().apply { responses += "{}" }
        val repository = AuthRepository(
            config = DayPageCloudConfig(
                supabaseUrl = "https://project.supabase.co",
                anonKey = "public-anon-key",
                redirectUri = "daypage://auth/callback",
            ),
            httpClient = OkHttpClient.Builder().addInterceptor(transport).build(),
            secureStore = MemorySecureStore(),
            syncScheduler = RecordingScheduler(),
        )

        repository.sendEmailLink(" person@example.com ")

        val request = transport.requests.single()
        assertEquals("/auth/v1/otp", request.url.encodedPath)
        assertEquals("daypage://auth/callback", request.url.queryParameter("redirect_to"))
        val body = JSONObject(request.bodyText())
        assertEquals("person@example.com", body.getString("email"))
        assertFalse(body.has("email_redirect_to"))
        assertEquals("S256", body.getString("code_challenge_method"))
        assertTrue(body.getString("code_challenge").length >= 43)
        assertEquals(AccountState.Authenticating, repository.state.value)
    }

    @Test
    fun applePkceCallbackCreatesSameAccountSessionAndLocalSignOutClearsIt() = runTest {
        val transport = RecordingTransport()
        transport.responses += tokenResponse()
        transport.responses += ""
        val store = MemorySecureStore()
        val scheduler = RecordingScheduler()
        val repository = AuthRepository(
            config = DayPageCloudConfig(
                supabaseUrl = "https://project.supabase.co",
                anonKey = "public-anon-key",
                redirectUri = "daypage://auth/callback",
            ),
            httpClient = OkHttpClient.Builder().addInterceptor(transport).build(),
            secureStore = store,
            syncScheduler = scheduler,
        )

        val authorization = Uri.parse(repository.appleAuthorizationUrl())
        assertEquals("apple", authorization.getQueryParameter("provider"))
        assertEquals("S256", authorization.getQueryParameter("code_challenge_method"))
        assertTrue(authorization.getQueryParameter("code_challenge").orEmpty().length >= 43)
        assertFalse(authorization.getQueryParameter("state").isNullOrBlank())

        repository.handleCallback(Uri.parse("daypage://auth/callback?code=authorization-code"))

        val state = repository.state.value as AccountState.BoundAndSyncing
        assertEquals("40000000-0000-4000-8000-000000000001", state.account.userId)
        assertEquals("person@example.com", state.account.email)
        assertEquals("access-token", repository.accessToken())
        assertEquals(1, scheduler.expeditedRequests)
        val exchange = transport.requests.first()
        assertEquals("/auth/v1/token?grant_type=pkce", exchange.url.encodedPathAndQuery())
        assertEquals("public-anon-key", exchange.header("apikey"))
        val exchangeJson = JSONObject(exchange.bodyText())
        assertEquals("authorization-code", exchangeJson.getString("auth_code"))
        assertTrue(exchangeJson.getString("code_verifier").length >= 43)

        repository.signOutThisDevice()

        assertEquals(AccountState.LocalOnly, repository.state.value)
        assertEquals("/auth/v1/logout?scope=local", transport.requests.last().url.encodedPathAndQuery())
        assertTrue(store.values.isEmpty())
    }

    private fun tokenResponse() = JSONObject()
        .put("access_token", "access-token")
        .put("refresh_token", "refresh-token")
        .put("expires_at", 4_000_000_000L)
        .put(
            "user",
            JSONObject()
                .put("id", "40000000-0000-4000-8000-000000000001")
                .put("email", "person@example.com"),
        )
        .toString()

    private class MemorySecureStore : SecureStore {
        val values = mutableMapOf<String, String>()
        override fun put(key: String, value: String) {
            values[key] = value
        }
        override fun get(key: String): String? = values[key]
        override fun remove(key: String) {
            values.remove(key)
        }
    }

    private class RecordingScheduler : SyncRequestScheduler {
        var expeditedRequests = 0
        override fun requestSync() = Unit
        override fun requestExpeditedSync() {
            expeditedRequests += 1
        }
    }

    private class RecordingTransport : Interceptor {
        val requests = mutableListOf<Request>()
        val responses = ArrayDeque<String>()

        override fun intercept(chain: Interceptor.Chain): Response {
            val request = chain.request()
            requests += request
            val body = responses.removeFirst()
            return Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(if (body.isEmpty()) 204 else 200)
                .message("OK")
                .body(body.toResponseBody("application/json".toMediaType()))
                .build()
        }
    }
}

private fun Request.bodyText(): String = Buffer().also { buffer -> body?.writeTo(buffer) }.readUtf8()

private fun okhttp3.HttpUrl.encodedPathAndQuery(): String =
    encodedPath + encodedQuery?.let { "?$it" }.orEmpty()
