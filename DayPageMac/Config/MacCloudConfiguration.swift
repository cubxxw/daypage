import Foundation

/// Public connection metadata for the native Mac client.
///
/// The bundled fallback intentionally targets the isolated DayPage staging
/// project. Both values are public client configuration (never a service-role
/// or DayPage PAT). A release pipeline can override them through generated
/// Info.plist keys without changing source.
struct MacCloudConfiguration: Equatable {
    let supabaseURL: URL
    let publishableKey: String

    static func current(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MacCloudConfiguration {
        let urlString = firstNonEmpty(
            environment["DAYPAGE_SUPABASE_URL"],
            bundle.object(forInfoDictionaryKey: "DayPageSupabaseURL") as? String,
            "https://gcukhewnszjrwfzhxctn.supabase.co"
        )
        let key = firstNonEmpty(
            environment["DAYPAGE_SUPABASE_PUBLISHABLE_KEY"],
            bundle.object(forInfoDictionaryKey: "DayPageSupabasePublishableKey") as? String,
            "sb_publishable_bE_AwZrkhj6ypsEX0p6Cgw_LaRQ1M91"
        )
        // The checked-in fallbacks above are constants, so this can only fail
        // after an invalid deployment override. Fail loudly instead of routing
        // a user's notes to an ambiguous host.
        guard let url = URL(string: urlString), url.scheme == "https" else {
            preconditionFailure("Invalid DayPage Supabase URL")
        }
        return MacCloudConfiguration(supabaseURL: url, publishableKey: key)
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        values.lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }
}
