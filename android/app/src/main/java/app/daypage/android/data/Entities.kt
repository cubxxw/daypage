package app.daypage.android.data

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(tableName = "memos")
data class MemoEntity(
    @PrimaryKey val id: String,
    val type: String,
    val body: String,
    val createdAt: String,
    val modifiedAt: String,
    val revision: Long,
    val sourceDeviceId: String,
    val pinnedAt: String? = null,
    val locationJson: String? = null,
    val weatherJson: String? = null,
    val device: String? = null,
    val source: String? = "android",
    val vaultPath: String? = null,
    val deletedAt: String? = null,
)

@Entity(
    tableName = "sync_outbox",
    indices = [Index(value = ["operationId"], unique = true), Index(value = ["memoId"])],
)
data class SyncOutboxEntity(
    @PrimaryKey(autoGenerate = true) val localId: Long = 0,
    val operationId: String,
    val memoId: String,
    val kind: String,
    val revision: Long,
    val modifiedAt: String,
    val contentHash: String?,
    val deviceId: String,
    val payloadJson: String?,
    val sizeBytes: Int,
    val attemptCount: Int = 0,
    val lastError: String? = null,
)

@Entity(tableName = "sync_cursor")
data class SyncCursorEntity(
    @PrimaryKey val accountId: String,
    val cursor: Long,
)
