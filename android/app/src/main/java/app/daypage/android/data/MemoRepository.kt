package app.daypage.android.data

import app.daypage.android.sync.SyncRequestScheduler
import kotlinx.coroutines.flow.Flow
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.time.Clock
import java.time.Instant
import java.util.UUID

class MemoRepository(
    private val dao: DayPageDao,
    private val syncScheduler: SyncRequestScheduler,
    private val deviceId: String,
    private val vaultStore: AndroidVaultStore,
    private val clock: Clock = Clock.systemUTC(),
) {
    val memos: Flow<List<MemoEntity>> = dao.observeMemos()
    val pendingCount: Flow<Int> = dao.observePendingCount()

    suspend fun capture(rawBody: String): String {
        val body = rawBody.trim()
        require(body.isNotEmpty()) { "A Noter cannot be empty" }
        val id = UUID.randomUUID().toString().lowercase()
        val now = Instant.now(clock).toString()
        val memo = MemoEntity(
            id = id,
            type = "text",
            body = body,
            createdAt = now,
            modifiedAt = now,
            revision = 1,
            sourceDeviceId = deviceId,
        )
        val vaultWrite = vaultStore.append(memo)
        dao.capture(memo, makeOperation(memo, vaultWrite.vaultPath, vaultWrite.markdown))
        syncScheduler.requestExpeditedSync()
        return id
    }

    suspend fun reconcileVault() {
        var repaired = false
        vaultStore.readAll(deviceId).forEach { record ->
            if (dao.memo(record.memo.id) == null) {
                dao.capture(
                    record.memo,
                    makeOperation(record.memo, record.vaultPath, record.markdown),
                )
                repaired = true
            }
        }
        if (repaired) syncScheduler.requestSync()
    }

    private fun makeOperation(
        memo: MemoEntity,
        vaultPath: String,
        markdown: String,
    ): SyncOutboxEntity {
        val payload = JSONObject()
            .put("type", memo.type)
            .put("body", memo.body)
            .put("created_at", memo.createdAt)
            .put("device", memo.device ?: "Android")
            .put("source", memo.source ?: "android")
            .put("vault_path", vaultPath)
        return SyncOutboxEntity(
            operationId = UUID.randomUUID().toString().lowercase(),
            memoId = memo.id,
            kind = "upsert",
            revision = memo.revision,
            modifiedAt = memo.modifiedAt,
            contentHash = sha256(markdown),
            deviceId = deviceId,
            payloadJson = payload.toString(),
            sizeBytes = markdown.toByteArray(StandardCharsets.UTF_8).size,
        )
    }

    private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(StandardCharsets.UTF_8))
        .joinToString(separator = "") { byte -> "%02x".format(byte) }
}
