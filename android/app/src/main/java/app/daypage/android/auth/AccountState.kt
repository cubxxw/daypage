package app.daypage.android.auth

sealed interface AccountState {
    data object LocalOnly : AccountState
    data object Authenticating : AccountState
    data class BoundAndSyncing(val account: AccountIdentity) : AccountState
    data class Synced(val account: AccountIdentity) : AccountState
    data class OfflineQueued(val account: AccountIdentity, val pendingCount: Int) : AccountState
    data class ActionRequired(val message: String, val account: AccountIdentity? = null) : AccountState
}

data class AccountIdentity(
    val userId: String,
    val email: String?,
)

data class UserSession(
    val accessToken: String,
    val refreshToken: String,
    val expiresAtEpochSeconds: Long,
    val account: AccountIdentity,
)
