package app.daypage.android.data

import androidx.room.AutoMigration
import androidx.room.Database
import androidx.room.RoomDatabase

@Database(
    entities = [MemoEntity::class, SyncOutboxEntity::class, SyncCursorEntity::class],
    version = 3,
    autoMigrations = [
        AutoMigration(from = 1, to = 2),
        AutoMigration(from = 2, to = 3),
    ],
    exportSchema = true,
)
abstract class DayPageDatabase : RoomDatabase() {
    abstract fun dayPageDao(): DayPageDao
}
