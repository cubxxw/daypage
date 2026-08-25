package app.daypage.android.sync

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import java.time.Duration

interface SyncRequestScheduler {
    fun requestSync()
    fun requestExpeditedSync()
}

class SyncScheduler(context: Context) : SyncRequestScheduler {
    private val workManager = WorkManager.getInstance(context.applicationContext)

    override fun requestSync() {
        enqueue(expedited = false)
    }

    override fun requestExpeditedSync() {
        enqueue(expedited = true)
    }

    private fun enqueue(expedited: Boolean) {
        val builder = OneTimeWorkRequestBuilder<SyncWorker>()
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.CONNECTED)
                    .build(),
            )
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, Duration.ofSeconds(20))
        if (expedited) {
            builder.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
        }
        workManager.enqueueUniqueWork(
            UNIQUE_WORK,
            ExistingWorkPolicy.APPEND_OR_REPLACE,
            builder.build(),
        )
    }

    private companion object {
        const val UNIQUE_WORK = "daypage-account-sync"
    }
}
