package app.daypage.android.sync

import app.daypage.android.auth.AuthRepository
import app.daypage.android.auth.DayPageCloudConfig
import app.daypage.android.data.SyncOutboxEntity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

class SupabaseSyncGateway(
    private val config: DayPageCloudConfig,
    private val httpClient: OkHttpClient,
    private val authRepository: AuthRepository,
) {
    suspend fun push(operations: List<SyncOutboxEntity>): PushResult {
        require(operations.isNotEmpty() && operations.size <= 100)
        val payload = JSONObject().put(
            "p_operations",
            JSONArray().apply { operations.forEach { put(it.asWireJson()) } },
        )
        val response = execute(
            endpoint = "daypage_apply_sync_operations",
            payload = payload,
        )
        val result = parsePushResult(response)
        val requestedIds = operations.map { it.operationId }.toSet()
        val receiptIds = result.accepted.map { it.operationId }.toSet() + result.rejectedOperationIds
        if (receiptIds != requestedIds) {
            throw SyncProtocolException("The cloud returned an incomplete operation receipt.")
        }
        return result
    }

    suspend fun pull(after: Long, limit: Int = 200): RemotePage {
        val payload = JSONObject()
            .put("p_after_sequence", after.coerceAtLeast(0))
            .put("p_limit", limit.coerceIn(1, 500))
        return parseRemotePage(
            execute(endpoint = "daypage_pull_sync_changes", payload = payload),
        )
    }

    private suspend fun execute(endpoint: String, payload: JSONObject): JSONObject {
        if (!config.isConfigured) throw SyncConfigurationException()
        val token = authRepository.accessToken()
        val request = Request.Builder()
            .url("${config.supabaseUrl}/rest/v1/rpc/$endpoint")
            .header("apikey", config.anonKey)
            .header("Authorization", "Bearer $token")
            .header("Content-Type", "application/json")
            .header("Accept", "application/json")
            .post(payload.toString().toRequestBody(JSON_MEDIA_TYPE))
            .build()
        return withContext(Dispatchers.IO) {
            httpClient.newCall(request).execute().use { response ->
                val text = response.body.string()
                when {
                    response.isSuccessful -> JSONObject(text)
                    response.code == 401 || response.code == 403 ->
                        throw SyncAuthorizationException()
                    response.code == 429 || response.code >= 500 ->
                        throw RetryableSyncException("Cloud sync is temporarily unavailable.")
                    else -> throw SyncProtocolException("Cloud sync failed (${response.code}).")
                }
            }
        }
    }

    private companion object {
        val JSON_MEDIA_TYPE = "application/json".toMediaType()
    }
}

class SyncConfigurationException : Exception("Cloud sync is not configured.")
class SyncAuthorizationException : Exception("Your session needs attention. Sign in again.")
class RetryableSyncException(message: String) : Exception(message)
class SyncProtocolException(message: String) : Exception(message)
