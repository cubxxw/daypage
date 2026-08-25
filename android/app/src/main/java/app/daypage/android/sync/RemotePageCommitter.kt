package app.daypage.android.sync

import app.daypage.android.data.DayPageDao
import app.daypage.android.data.RemoteVaultWriter
import app.daypage.android.data.SyncCursorEntity

/**
 * Owns the cross-store commit boundary for a pulled page. Room can be replayed,
 * but the server cursor is durable only after the canonical Markdown mirror is.
 */
class RemotePageCommitter(
    private val dao: DayPageDao,
    private val vaultWriter: RemoteVaultWriter,
) {
    suspend fun commit(accountId: String, page: RemotePage) {
        val vaultChanges = dao.applyRemoteChanges(page.changes.map(RemoteChange::asEntity))
        vaultWriter.applyRemoteChanges(vaultChanges)
        dao.setCursor(SyncCursorEntity(accountId, page.nextCursor))
    }
}
