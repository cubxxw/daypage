package app.daypage.android.sync

import app.daypage.android.data.MemoEntity
import app.daypage.android.data.SyncOutboxEntity
import org.json.JSONArray
import org.json.JSONObject

data class SyncReceipt(
    val operationId: String,
    val status: String,
    val remoteRevision: Long?,
)

data class PushResult(
    val accepted: List<SyncReceipt>,
    val rejectedOperationIds: Set<String>,
)

data class RemotePage(
    val changes: List<RemoteChange>,
    val nextCursor: Long,
    val hasMore: Boolean,
) {
    fun isValid(after: Long): Boolean {
        val sequences = changes.map { it.changeSequence }
        if (nextCursor < after || sequences.any { it <= after }) return false
        if (sequences != sequences.sorted() || sequences.distinct().size != sequences.size) return false
        return sequences.lastOrNull()?.let { nextCursor == it } ?: (nextCursor == after && !hasMore)
    }
}

data class RemoteChange(
    val id: String,
    val type: String,
    val body: String,
    val createdAt: String,
    val pinnedAt: String?,
    val locationJson: String?,
    val weatherJson: String?,
    val device: String?,
    val source: String,
    val vaultPath: String?,
    val sourceModifiedAt: String?,
    val syncRevision: Long,
    val lastSyncDeviceId: String?,
    val deletedAt: String?,
    val changeSequence: Long,
) {
    fun asEntity(): MemoEntity = MemoEntity(
        id = id,
        type = type,
        body = body,
        createdAt = createdAt,
        modifiedAt = sourceModifiedAt ?: createdAt,
        revision = syncRevision,
        sourceDeviceId = lastSyncDeviceId.orEmpty(),
        pinnedAt = pinnedAt,
        locationJson = locationJson,
        weatherJson = weatherJson,
        device = device,
        source = source,
        vaultPath = vaultPath,
        deletedAt = deletedAt,
    )
}

fun SyncOutboxEntity.asWireJson(): JSONObject = JSONObject()
    .put("operation_id", operationId)
    .put("memo_id", memoId)
    .put("kind", kind)
    .put("revision", revision)
    .put("modified_at", modifiedAt)
    .put("content_hash", contentHash ?: JSONObject.NULL)
    .put("device_id", deviceId)
    .put("payload", payloadJson?.let(::JSONObject) ?: JSONObject.NULL)
    .put("size_bytes", sizeBytes)

fun parsePushResult(json: JSONObject): PushResult {
    val accepted = json.getJSONArray("accepted").objects().map { item ->
        SyncReceipt(
            operationId = item.getString("operation_id"),
            status = item.getString("status"),
            remoteRevision = item.optLongOrNull("remote_revision"),
        )
    }
    val rejected = json.getJSONArray("rejected").objects().mapNotNull { item ->
        item.optString("operation_id").takeIf(String::isNotBlank)
    }.toSet()
    return PushResult(accepted = accepted, rejectedOperationIds = rejected)
}

fun parseRemotePage(json: JSONObject): RemotePage = RemotePage(
    changes = json.getJSONArray("changes").objects().map { item ->
        RemoteChange(
            id = item.getString("id"),
            type = item.getString("type"),
            body = item.getString("body"),
            createdAt = item.getString("created_at"),
            pinnedAt = item.optNullableString("pinned_at"),
            locationJson = item.optNullableJson("location"),
            weatherJson = item.optNullableJson("weather"),
            device = item.optNullableString("device"),
            source = item.getString("source"),
            vaultPath = item.optNullableString("vault_path"),
            sourceModifiedAt = item.optNullableString("source_modified_at"),
            syncRevision = item.getLong("sync_revision"),
            lastSyncDeviceId = item.optNullableString("last_sync_device_id"),
            deletedAt = item.optNullableString("deleted_at"),
            changeSequence = item.getLong("change_sequence"),
        )
    },
    nextCursor = json.getLong("next_cursor"),
    hasMore = json.getBoolean("has_more"),
)

private fun JSONArray.objects(): List<JSONObject> = buildList {
    for (index in 0 until length()) add(getJSONObject(index))
}

private fun JSONObject.optNullableString(key: String): String? =
    if (!has(key) || isNull(key)) null else getString(key)

private fun JSONObject.optNullableJson(key: String): String? =
    if (!has(key) || isNull(key)) null else get(key).let { value ->
        if (value is String) JSONObject.quote(value) else value.toString()
    }

private fun JSONObject.optLongOrNull(key: String): Long? =
    if (!has(key) || isNull(key)) null else getLong(key)
