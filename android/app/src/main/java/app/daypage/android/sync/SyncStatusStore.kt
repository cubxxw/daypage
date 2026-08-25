package app.daypage.android.sync

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

sealed interface SyncStatus {
    data object Idle : SyncStatus
    data object Syncing : SyncStatus
    data class OfflineQueued(val pendingCount: Int) : SyncStatus
    data class ActionRequired(val message: String) : SyncStatus
}

class SyncStatusStore {
    private val _status = MutableStateFlow<SyncStatus>(SyncStatus.Idle)
    val status: StateFlow<SyncStatus> = _status.asStateFlow()

    fun update(status: SyncStatus) {
        _status.value = status
    }
}
