package app.daypage.android

import android.content.Context
import androidx.room.Room
import app.daypage.android.auth.AuthRepository
import app.daypage.android.auth.DayPageCloudConfig
import app.daypage.android.auth.SecureValueStore
import app.daypage.android.data.DayPageDatabase
import app.daypage.android.data.DeviceIdentity
import app.daypage.android.data.AndroidVaultStore
import app.daypage.android.data.MemoRepository
import app.daypage.android.sync.SupabaseSyncGateway
import app.daypage.android.sync.RemotePageCommitter
import app.daypage.android.sync.SyncScheduler
import app.daypage.android.sync.SyncStatusStore
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

class AppContainer(context: Context) {
    private val applicationContext = context.applicationContext

    val database: DayPageDatabase = Room.databaseBuilder(
        applicationContext,
        DayPageDatabase::class.java,
        "daypage.db",
    ).build()

    val httpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .writeTimeout(20, TimeUnit.SECONDS)
        .build()

    val cloudConfig = DayPageCloudConfig(
        supabaseUrl = BuildConfig.SUPABASE_URL.trimEnd('/'),
        anonKey = BuildConfig.SUPABASE_ANON_KEY,
        redirectUri = "daypage://auth/callback",
    )
    val secureStore = SecureValueStore(applicationContext)
    val deviceIdentity = DeviceIdentity(applicationContext)
    val vaultStore = AndroidVaultStore(applicationContext)
    val syncStatus = SyncStatusStore()
    val syncScheduler = SyncScheduler(applicationContext)
    val authRepository = AuthRepository(
        config = cloudConfig,
        httpClient = httpClient,
        secureStore = secureStore,
        syncScheduler = syncScheduler,
    )
    val memoRepository = MemoRepository(
        dao = database.dayPageDao(),
        syncScheduler = syncScheduler,
        deviceId = deviceIdentity.id,
        vaultStore = vaultStore,
    )
    val remotePageCommitter = RemotePageCommitter(database.dayPageDao(), vaultStore)
    val syncGateway = SupabaseSyncGateway(
        config = cloudConfig,
        httpClient = httpClient,
        authRepository = authRepository,
    )
}
