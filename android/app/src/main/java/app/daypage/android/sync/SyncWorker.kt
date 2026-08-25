package app.daypage.android.sync

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import app.daypage.android.DayPageApplication
import app.daypage.android.auth.AuthException

class SyncWorker(
    appContext: Context,
    workerParameters: WorkerParameters,
) : CoroutineWorker(appContext, workerParameters) {
    override suspend fun doWork(): Result {
        val container = (applicationContext as DayPageApplication).container
        val dao = container.database.dayPageDao()
        val auth = container.authRepository
        val status = container.syncStatus

        status.update(SyncStatus.Syncing)
        return try {
            val account = auth.currentAccount() ?: run {
                status.update(SyncStatus.Idle)
                return Result.success()
            }

            val operations = dao.pendingOperations(limit = 100)
            var sawStaleReceipt = false
            if (operations.isNotEmpty()) {
                val result = container.syncGateway.push(operations)
                result.accepted.forEach { receipt ->
                    when (receipt.status) {
                        "applied" -> dao.acknowledge(receipt.operationId)
                        "stale" -> {
                            dao.recordFailure(receipt.operationId, "remote_revision_${receipt.remoteRevision}")
                            sawStaleReceipt = true
                        }
                        else -> throw SyncProtocolException("The cloud returned an unknown receipt status.")
                    }
                }
                result.rejectedOperationIds.forEach { operationId ->
                    dao.recordFailure(operationId, "rejected")
                }
                if (result.rejectedOperationIds.isNotEmpty()) {
                    throw SyncProtocolException("One or more local changes need attention.")
                }
            }

            var cursor = dao.cursor(account.userId) ?: 0
            var pageCount = 0
            do {
                val page = container.syncGateway.pull(after = cursor)
                if (!page.isValid(after = cursor)) {
                    throw SyncProtocolException("The cloud returned an invalid sync cursor.")
                }
                container.remotePageCommitter.commit(account.userId, page)
                cursor = page.nextCursor
                pageCount += 1
            } while (page.hasMore && pageCount < MAX_PAGES_PER_RUN)

            val remaining = dao.pendingOperations(limit = 100).size
            if (pageCount == MAX_PAGES_PER_RUN || sawStaleReceipt || remaining > 0) {
                container.syncScheduler.requestSync()
            }
            if (remaining == 0) {
                auth.markSynced()
                status.update(SyncStatus.Idle)
            } else {
                status.update(SyncStatus.OfflineQueued(remaining))
            }
            Result.success()
        } catch (_: SyncConfigurationException) {
            status.update(SyncStatus.Idle)
            Result.success()
        } catch (error: SyncAuthorizationException) {
            auth.markSyncActionRequired(error.message.orEmpty())
            status.update(SyncStatus.ActionRequired(error.message.orEmpty()))
            Result.failure()
        } catch (error: SyncProtocolException) {
            auth.markSyncActionRequired(error.message.orEmpty())
            status.update(SyncStatus.ActionRequired(error.message.orEmpty()))
            Result.failure()
        } catch (error: AuthException) {
            auth.markSyncActionRequired(error.message.orEmpty())
            status.update(SyncStatus.ActionRequired(error.message.orEmpty()))
            Result.failure()
        } catch (error: Exception) {
            val pending = dao.pendingOperations(limit = 100).size
            status.update(SyncStatus.OfflineQueued(pending))
            if (runAttemptCount >= 5) Result.failure() else Result.retry()
        }
    }

    private companion object {
        const val MAX_PAGES_PER_RUN = 5
    }
}
