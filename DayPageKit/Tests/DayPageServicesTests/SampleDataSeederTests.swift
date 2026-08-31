import XCTest
@testable import DayPageServices
import DayPageStorage

final class SampleDataSeederTests: XCTestCase {
    private var vaultURL: URL!
    private var previousTimeZone: Any?
    private var previousSeededValue: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SampleDataSeederTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = vaultURL

        previousTimeZone = UserDefaults.standard.object(forKey: StorageSettings.preferredTimeZoneKey)
        previousSeededValue = UserDefaults.standard.object(forKey: "hasSeededSamples")
        UserDefaults.standard.set("Asia/Shanghai", forKey: StorageSettings.preferredTimeZoneKey)
        UserDefaults.standard.set(false, forKey: "hasSeededSamples")
        VaultInitializer.initializeIfNeeded()
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        restore(previousTimeZone, forKey: StorageSettings.preferredTimeZoneKey)
        restore(previousSeededValue, forKey: "hasSeededSamples")
        try? FileManager.default.removeItem(at: vaultURL)
        try super.tearDownWithError()
    }

    func testSeededRawAndDailyUseTheSamePreferredTimeZoneDate() throws {
        SampleDataSeeder.seedIfNeeded()

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: Date()))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = calendar.timeZone
        let expectedDate = formatter.string(from: yesterday)

        let rawURL = vaultURL.appendingPathComponent("raw/\(expectedDate).md")
        let dailyURL = vaultURL.appendingPathComponent("wiki/daily/\(expectedDate).md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rawURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dailyURL.path))
        XCTAssertEqual(try RawStorage.read(for: yesterday).count, 3)
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
