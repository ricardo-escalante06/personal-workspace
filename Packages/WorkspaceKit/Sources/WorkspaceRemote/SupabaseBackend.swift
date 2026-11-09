import Foundation
import Supabase
import WorkspaceKit

/// Connection settings, read from the app's Info.plist (filled from Config/Secrets.xcconfig).
public struct BackendConfig: Sendable, Equatable {
    public var url: URL
    public var anonKey: String

    public init(url: URL, anonKey: String) {
        self.url = url
        self.anonKey = anonKey
    }

    /// nil when the app was built without Supabase credentials (local-only mode).
    public static func fromInfoPlist(_ bundle: Bundle = .main) -> BackendConfig? {
        guard
            let host = (bundle.object(forInfoDictionaryKey: "SupabaseHost") as? String)?
                .trimmingCharacters(in: .whitespaces),
            let key = (bundle.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String)?
                .trimmingCharacters(in: .whitespaces),
            !host.isEmpty, !key.isEmpty, !host.hasPrefix("$("),
            let url = URL(string: host.hasPrefix("http") ? host : "https://\(host)")
        else { return nil }
        return BackendConfig(url: url, anonKey: key)
    }
}

/// Auth and sync transport for Supabase.
public final class SupabaseBackend: Sendable {
    public let client: SupabaseClient

    public init(config: BackendConfig) {
        client = SupabaseClient(
            supabaseURL: config.url,
            supabaseKey: config.anonKey,
            options: SupabaseClientOptions(auth: .init(emitLocalSessionAsInitialSession: true))
        )
    }

    public var remote: SupabaseSyncRemote { SupabaseSyncRemote(client: client) }

    /// The signed-in user's id, or nil.
    public func currentUserId() async -> UUID? {
        guard let session = try? await client.auth.session, !session.isExpired else { return nil }
        return session.user.id
    }

    /// Exchanges an Apple identity token for a Supabase session.
    /// `nonce` is the raw nonce whose SHA-256 was sent in the Apple request.
    @discardableResult
    public func signInWithApple(idToken: String, nonce: String) async throws -> UUID {
        let session = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
        )
        return session.user.id
    }

    public func signOut() async throws {
        try await client.auth.signOut()
    }

    /// Subscribes to row changes on the user's synced tables (RLS-filtered by
    /// Realtime) and calls `onChange` for each one. Payloads are ignored: the
    /// event only means "pull now". Cancel the returned feed to unsubscribe.
    public func startChangeFeed(onChange: @escaping @Sendable () async -> Void) async throws -> ChangeFeed {
        let channel = client.channel("workspace-sync-\(UUID().uuidString.prefix(8))")
        let changes = channel.postgresChange(AnyAction.self, schema: "public")
        try await channel.subscribeWithError()
        let listener = Task {
            for await _ in changes {
                await onChange()
            }
        }
        return ChangeFeed(client: client, channel: channel, listener: listener)
    }
}

/// A live Realtime subscription. Call `cancel()` on sign-out.
public final class ChangeFeed: Sendable {
    let client: SupabaseClient
    let channel: RealtimeChannelV2
    let listener: Task<Void, Never>

    init(client: SupabaseClient, channel: RealtimeChannelV2, listener: Task<Void, Never>) {
        self.client = client
        self.channel = channel
        self.listener = listener
    }

    public func cancel() async {
        listener.cancel()
        await client.removeChannel(channel)
    }
}

/// `SyncRemote` over PostgREST. RLS on the server scopes every query to the signed-in user.
public struct SupabaseSyncRemote: SyncRemote {
    let client: SupabaseClient

    public func push(table: String, rows: Data) async throws -> Data {
        let values = try JSONDecoder().decode([AnyJSON].self, from: rows)
        let response = try await client
            .from(table)
            .upsert(values, onConflict: "id")
            .select()
            .execute()
        return response.data
    }

    public func pull(table: String, after: Date?, limit: Int) async throws -> Data {
        let base = client.from(table).select()
        let filtered = if let after {
            base.gt("updated_at", value: ISODate.format(after))
        } else {
            base
        }
        let response = try await filtered
            .order("updated_at", ascending: true)
            .limit(limit)
            .execute()
        return response.data
    }
}
