package app.daypage.android.data

import android.app.Application
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.daypage.android.sync.SyncRequestScheduler
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class MemoRepositoryTest {
    @get:Rule
    val temporaryFolder = TemporaryFolder()

    private lateinit var database: DayPageDatabase
    private lateinit var vaultStore: AndroidVaultStore
    private lateinit var scheduler: RecordingScheduler

    @Before
    fun setUp() {
        database = Room.inMemoryDatabaseBuilder(
            ApplicationProvider.getApplicationContext(),
            DayPageDatabase::class.java,
        ).allowMainThreadQueries().build()
        vaultStore = AndroidVaultStore.forTesting(temporaryFolder.newFolder("vault"))
        scheduler = RecordingScheduler()
    }

    @After
    fun tearDown() {
        database.close()
    }

    @Test
    fun captureWritesCanonicalVaultBeforeQueuingSync() = runTest {
        val repository = repository()

        val memoId = repository.capture("local-first Android")

        assertEquals("local-first Android", database.dayPageDao().memo(memoId)?.body)
        assertEquals(1, database.dayPageDao().observePendingCount().first())
        assertTrue(vaultStore.rawFile("2026-08-25").readText().contains("local-first Android"))
        assertEquals(1, scheduler.expeditedRequests)
    }

    @Test
    fun reconcileRepairsRoomAndOutboxFromRawVault() = runTest {
        vaultStore.append(
            MemoEntity(
                id = "20000000-0000-4000-8000-000000000001",
                type = "text",
                body = "survived interrupted index write",
                createdAt = "2026-08-25T00:00:00Z",
                modifiedAt = "2026-08-25T00:00:00Z",
                revision = 1,
                sourceDeviceId = DEVICE_ID,
            ),
        )

        repository().reconcileVault()

        assertEquals(1, database.dayPageDao().observeMemos().first().size)
        assertEquals(1, database.dayPageDao().observePendingCount().first())
        assertEquals(1, scheduler.regularRequests)
    }

    private fun repository() = MemoRepository(
        dao = database.dayPageDao(),
        syncScheduler = scheduler,
        deviceId = DEVICE_ID,
        vaultStore = vaultStore,
        clock = Clock.fixed(Instant.parse("2026-08-25T12:34:56Z"), ZoneOffset.UTC),
    )

    private class RecordingScheduler : SyncRequestScheduler {
        var regularRequests = 0
        var expeditedRequests = 0

        override fun requestSync() {
            regularRequests += 1
        }

        override fun requestExpeditedSync() {
            expeditedRequests += 1
        }
    }

    private companion object {
        const val DEVICE_ID = "30000000-0000-4000-8000-000000000001"
    }
}
