package app.daypage.android.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import kotlinx.coroutines.flow.Flow
import java.util.UUID

@Dao
abstract class DayPageDao {
    @Query("SELECT * FROM memos WHERE deletedAt IS NULL ORDER BY createdAt DESC")
    abstract fun observeMemos(): Flow<List<MemoEntity>>

    @Query("SELECT COUNT(*) FROM sync_outbox")
    abstract fun observePendingCount(): Flow<Int>

    @Query("SELECT * FROM memos WHERE id = :memoId LIMIT 1")
    abstract suspend fun memo(memoId: String): MemoEntity?

    @Query("SELECT EXISTS(SELECT 1 FROM sync_outbox WHERE memoId = :memoId)")
    abstract suspend fun hasPendingOperation(memoId: String): Boolean

    @Query("SELECT * FROM sync_outbox ORDER BY localId ASC LIMIT :limit")
    abstract suspend fun pendingOperations(limit: Int): List<SyncOutboxEntity>

    @Query("SELECT * FROM sync_outbox WHERE memoId = :memoId LIMIT 1")
    abstract suspend fun pendingOperation(memoId: String): SyncOutboxEntity?

    @Query("DELETE FROM sync_outbox WHERE operationId = :operationId")
    abstract suspend fun acknowledge(operationId: String)

    @Query("DELETE FROM sync_outbox WHERE memoId = :memoId")
    abstract suspend fun deleteOperationsForMemo(memoId: String)

    @Query(
        "UPDATE sync_outbox SET attemptCount = attemptCount + 1, lastError = :message " +
            "WHERE operationId = :operationId",
    )
    abstract suspend fun recordFailure(operationId: String, message: String)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract suspend fun upsertMemo(memo: MemoEntity)

    @Insert(onConflict = OnConflictStrategy.ABORT)
    abstract suspend fun insertOperation(operation: SyncOutboxEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract suspend fun setCursor(cursor: SyncCursorEntity)

    @Query("SELECT cursor FROM sync_cursor WHERE accountId = :accountId LIMIT 1")
    abstract suspend fun cursor(accountId: String): Long?

    @Transaction
    open suspend fun capture(memo: MemoEntity, operation: SyncOutboxEntity) {
        upsertMemo(memo)
        deleteOperationsForMemo(memo.id)
        insertOperation(operation)
    }

    @Transaction
    open suspend fun applyRemoteChanges(changes: List<MemoEntity>): List<MemoEntity> {
        val vaultChanges = mutableListOf<MemoEntity>()
        changes.forEach { change ->
            val local = memo(change.id)
            val pending = pendingOperation(change.id)
            val isConcurrentRemote = pending != null &&
                local != null &&
                change.sourceDeviceId != pending.deviceId &&
                change.revision >= pending.revision

            if (isConcurrentRemote) {
                val conflictId = UUID.randomUUID().toString().lowercase()
                val conflict = local.copy(id = conflictId, revision = 1)
                val conflictOperation = pending.copy(
                    localId = 0,
                    operationId = UUID.randomUUID().toString().lowercase(),
                    memoId = conflictId,
                    revision = 1,
                    attemptCount = 0,
                    lastError = null,
                )
                deleteOperationsForMemo(change.id)
                upsertMemo(conflict)
                insertOperation(conflictOperation)
                upsertMemo(change)
                vaultChanges += conflict
                vaultChanges += change
            } else if (pending == null && (local == null || change.revision >= local.revision)) {
                upsertMemo(change)
                vaultChanges += change
            }
        }
        return vaultChanges
    }
}
