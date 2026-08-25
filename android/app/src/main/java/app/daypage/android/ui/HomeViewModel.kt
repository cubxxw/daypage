package app.daypage.android.ui

import android.app.Application
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import app.daypage.android.DayPageApplication
import app.daypage.android.auth.AccountState
import app.daypage.android.data.MemoEntity
import app.daypage.android.sync.SyncStatus
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

data class HomeUiState(
    val memos: List<MemoEntity> = emptyList(),
    val pendingCount: Int = 0,
    val accountState: AccountState = AccountState.LocalOnly,
    val syncStatus: SyncStatus = SyncStatus.Idle,
    val notice: String? = null,
)

class HomeViewModel(application: Application) : AndroidViewModel(application) {
    private val container = (application as DayPageApplication).container
    private val notice = MutableStateFlow<String?>(null)

    val uiState: StateFlow<HomeUiState> = combine(
        container.memoRepository.memos,
        container.memoRepository.pendingCount,
        container.authRepository.state,
        container.syncStatus.status,
        notice,
    ) { memos, pending, account, sync, message ->
        HomeUiState(
            memos = memos,
            pendingCount = pending,
            accountState = account,
            syncStatus = sync,
            notice = message,
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5_000),
        initialValue = HomeUiState(),
    )

    fun capture(body: String, onSaved: () -> Unit) {
        viewModelScope.launch {
            runCatching { container.memoRepository.capture(body) }
                .onSuccess {
                    notice.value = null
                    onSaved()
                }
                .onFailure { notice.value = it.message }
        }
    }

    fun appleAuthorizationUrl(): String? = runCatching {
        container.authRepository.appleAuthorizationUrl()
    }.onFailure { notice.value = it.message }.getOrNull()

    fun sendEmailLink(email: String) {
        viewModelScope.launch {
            runCatching { container.authRepository.sendEmailLink(email) }
                .onSuccess { notice.value = MAGIC_LINK_SENT }
                .onFailure { notice.value = it.message }
        }
    }

    fun handleAuthCallback(uri: Uri) {
        viewModelScope.launch { container.authRepository.handleCallback(uri) }
    }

    fun signOutThisDevice() {
        viewModelScope.launch {
            container.authRepository.signOutThisDevice()
            notice.value = null
        }
    }

    fun retrySync() {
        notice.value = null
        container.syncScheduler.requestExpeditedSync()
    }

    fun consumeNotice() {
        notice.value = null
    }

    companion object {
        const val MAGIC_LINK_SENT = "magic_link_sent"
    }
}
