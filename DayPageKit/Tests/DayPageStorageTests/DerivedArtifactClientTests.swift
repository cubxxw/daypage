import XCTest
@testable import DayPageStorage

private actor ArtifactRecordingTransport: HTTPTransport {
    let responseData: Data
    let status: Int
    private var recordedRequests: [URLRequest] = []

    init(responseData: Data, status: Int = 200) {
        self.responseData = responseData
        self.status = status
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        recordedRequests.append(request)
        return (
            responseData,
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
        )
    }

    func lastRequest() -> URLRequest? { recordedRequests.last }
}

final class DerivedArtifactClientTests: XCTestCase {
    func testFetchDecodesCanonicalArtifactPayloadAndUsesSessionHeaders() async throws {
        let artifactID = UUID()
        let response = try JSONSerialization.data(withJSONObject: [[
            "id": artifactID.uuidString,
            "kind": "weekly_review",
            "schema_version": 1,
            "logical_key": "weekly:2026-08-24:Asia/Shanghai",
            "payload": ["trends": ["shipping", "sleep"], "narrative": "A grounded week"],
            "body_md": "## Week",
            "status": "live",
            "revision": 2,
            "source_set_hash": "abc",
            "local_date": "2026-08-24",
            "timezone": "Asia/Shanghai",
            "perspective_key": "canonical",
            "finalized_at": "2026-08-28T00:00:00.000Z",
            "created_at": "2026-08-28T00:00:00.000Z",
            "updated_at": "2026-08-28T00:01:00.000Z",
        ]])
        let transport = ArtifactRecordingTransport(responseData: response)
        let client = SupabaseDerivedArtifactClient(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "publishable",
            transport: transport,
            accessTokenProvider: { "session-token" }
        )

        let artifacts = try await client.fetchCanonicalArtifacts(limit: 50)

        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifacts[0].id, artifactID)
        XCTAssertEqual(artifacts[0].revision, 2)
        XCTAssertEqual(artifacts[0].payload["trends"]?.stringArrayValue, ["shipping", "sleep"])
        let recorded = await transport.lastRequest()
        let request = try XCTUnwrap(recorded)
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "publishable")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertTrue(request.url?.absoluteString.contains("perspective_key=eq.canonical") == true)
    }

    func testDailyRequestCallsNarrowRPCWithExplicitRetry() async throws {
        let jobID = UUID()
        let transport = ArtifactRecordingTransport(
            responseData: try JSONEncoder().encode(jobID.uuidString.lowercased())
        )
        let client = SupabaseDerivedArtifactClient(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "publishable",
            transport: transport,
            accessTokenProvider: { "session-token" }
        )

        let returned = try await client.requestDaily(
            localDate: "2026-08-27",
            timezone: "Asia/Shanghai",
            finalize: false,
            explicitRetry: true
        )

        XCTAssertEqual(returned, jobID)
        let recorded = await transport.lastRequest()
        let request = try XCTUnwrap(recorded)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.url?.path.hasSuffix("/rest/v1/rpc/daypage_request_daily_run") == true)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["p_local_date"] as? String, "2026-08-27")
        XCTAssertEqual(json["p_timezone"] as? String, "Asia/Shanghai")
        XCTAssertEqual(json["p_explicit_retry"] as? Bool, true)
    }
}
