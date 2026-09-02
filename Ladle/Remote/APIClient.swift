import Foundation
import LadleCore

struct APIConfiguration: Sendable {
    let baseURL: URL

    init(bundle: Bundle = .main) throws {
        guard
            let value = bundle.object(
                forInfoDictionaryKey: "LadleAPIBaseURL"
            ) as? String,
            let url = URL(string: value),
            let scheme = url.scheme,
            ["http", "https"].contains(scheme),
            url.host != nil
        else {
            throw APIError.invalidBaseURL
        }
        baseURL = url
    }

    init(baseURL: URL) {
        self.baseURL = baseURL
    }
}

actor APIClient {
    private struct EmptyBody: Encodable, Sendable {}

    /// What a request carries. JSON is nearly all of it; `raw` exists for the
    /// profile photo, which is already a JPEG and would cost a third more
    /// bytes wrapped in base64 inside an envelope. Both arrive here encoded,
    /// so everything downstream — the retry after a refresh included — is one
    /// path rather than two.
    private enum Payload {
        case empty
        case json(Data)
        case raw(Data, contentType: String)
    }

    private struct RefreshRequest: Encodable, Sendable {
        let refreshToken: String
        let deviceID: UUID
    }

    private let baseURL: URL
    private let session: URLSession
    private let tokenStore: any AuthTokenStoring
    private let appAttester: (any AppAttesting)?
    private let tunnelAccessKey: String?
    private let authenticationExpired: @Sendable () async -> Void
    private let sessionRefreshed: @Sendable (AuthTokens) async -> Void
    private var refreshTask: Task<AuthTokens, Error>?

    init(
        baseURL: URL,
        session: URLSession = .shared,
        tokenStore: any AuthTokenStoring,
        appAttester: (any AppAttesting)? = nil,
        tunnelAccessKey: String? = nil,
        authenticationExpired:
            @escaping @Sendable () async -> Void = {},
        sessionRefreshed:
            @escaping @Sendable (AuthTokens) async -> Void = { _ in }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenStore = tokenStore
        self.appAttester = appAttester
        self.tunnelAccessKey = tunnelAccessKey
        self.authenticationExpired = authenticationExpired
        self.sessionRefreshed = sessionRefreshed
    }

    func request<Response>(
        path: String,
        method: HTTPMethod = .get,
        authenticated: Bool = true,
        appAttestPurpose: AppAttestPurpose? = nil
    ) async throws -> Response
    where Response: Decodable & Sendable {
        try await request(
            path: path,
            method: method,
            payload: .empty,
            authenticated: authenticated,
            appAttestPurpose: appAttestPurpose
        )
    }

    func request<Response, Body>(
        path: String,
        method: HTTPMethod = .get,
        body: Body,
        authenticated: Bool = true,
        appAttestPurpose: AppAttestPurpose? = nil
    ) async throws -> Response
    where
        Response: Decodable & Sendable,
        Body: Encodable & Sendable
    {
        try await request(
            path: path,
            method: method,
            payload: .json(try encoded(body)),
            authenticated: authenticated,
            appAttestPurpose: appAttestPurpose
        )
    }

    /// A request whose body is bytes rather than JSON.
    func request<Response>(
        path: String,
        method: HTTPMethod,
        rawBody: Data,
        contentType: String,
        authenticated: Bool = true
    ) async throws -> Response
    where Response: Decodable & Sendable {
        try await request(
            path: path,
            method: method,
            payload: .raw(rawBody, contentType: contentType),
            authenticated: authenticated,
            appAttestPurpose: nil
        )
    }

    func requestWithoutResponse(
        path: String,
        method: HTTPMethod,
        authenticated: Bool = true
    ) async throws {
        try await requestWithoutResponse(
            path: path,
            method: method,
            body: Optional<EmptyBody>.none,
            authenticated: authenticated
        )
    }

    func requestWithoutResponse<Body>(
        path: String,
        method: HTTPMethod,
        body: Body,
        authenticated: Bool = true
    ) async throws
    where Body: Encodable & Sendable {
        try await requestWithoutResponse(
            path: path,
            method: method,
            body: Optional(body),
            authenticated: authenticated
        )
    }

    private func request<Response>(
        path: String,
        method: HTTPMethod,
        payload: Payload,
        authenticated: Bool,
        appAttestPurpose: AppAttestPurpose?
    ) async throws -> Response
    where Response: Decodable & Sendable {
        let tokens = authenticated ? try tokenStore.load() : nil
        if authenticated, tokens == nil {
            throw APIError.missingAuthentication
        }
        let request = try await authorizedRequest(
            path: path,
            method: method,
            payload: payload,
            accessToken: tokens?.accessToken,
            appAttestPurpose: appAttestPurpose
        )
        let (data, response) = try await perform(request)
        if response.statusCode == 401, authenticated {
            let refreshed = try await refreshTokens(
                failedAccessToken: tokens?.accessToken
            )
            let replay = try await authorizedRequest(
                path: path,
                method: method,
                payload: payload,
                accessToken: refreshed.accessToken,
                appAttestPurpose: appAttestPurpose
            )
            let (replayData, replayResponse) = try await perform(replay)
            if replayResponse.statusCode == 401 {
                await expireAuthentication()
                throw APIError.authenticationExpired
            }
            return try decode(
                Response.self,
                data: replayData,
                response: replayResponse
            )
        }
        return try decode(Response.self, data: data, response: response)
    }

    private func requestWithoutResponse<Body>(
        path: String,
        method: HTTPMethod,
        body: Body?,
        authenticated: Bool
    ) async throws
    where Body: Encodable & Sendable {
        let tokens = authenticated ? try tokenStore.load() : nil
        if authenticated, tokens == nil {
            throw APIError.missingAuthentication
        }
        var payload = Payload.empty
        if let body {
            payload = .json(try encoded(body))
        }
        let request = try makeRequest(
            path: path,
            method: method,
            payload: payload,
            accessToken: tokens?.accessToken
        )
        let (data, response) = try await perform(request)
        if response.statusCode == 401, authenticated {
            let refreshed = try await refreshTokens(
                failedAccessToken: tokens?.accessToken
            )
            let replay = try makeRequest(
                path: path,
                method: method,
                payload: payload,
                accessToken: refreshed.accessToken
            )
            let (replayData, replayResponse) = try await perform(replay)
            if replayResponse.statusCode == 401 {
                await expireAuthentication()
                throw APIError.authenticationExpired
            }
            try validateEmptyResponse(
                data: replayData,
                response: replayResponse
            )
            return
        }
        try validateEmptyResponse(data: data, response: response)
    }

    private func refreshTokens(
        failedAccessToken: String?
    ) async throws -> AuthTokens {
        if let current = try tokenStore.load(),
           current.accessToken != failedAccessToken
        {
            return current
        }
        if let refreshTask {
            return try await refreshTask.value
        }
        guard
            let current = try tokenStore.load(),
            let refreshToken = current.refreshToken
        else {
            await expireAuthentication()
            throw APIError.authenticationExpired
        }

        let request = try makeRequest(
            path: "/v1/auth/refresh",
            method: .post,
            payload: .json(
                try encoded(
                    RefreshRequest(
                        refreshToken: refreshToken,
                        deviceID: current.deviceID
                    )
                )
            ),
            accessToken: nil
        )
        let session = session
        let task = Task<AuthTokens, Error> {
            do {
                let (data, rawResponse) = try await session.data(for: request)
                guard let response = rawResponse as? HTTPURLResponse else {
                    throw APIError.invalidResponse
                }
                return try Self.decodeTokens(data: data, response: response)
            } catch let error as APIError {
                throw error
            } catch {
                throw APIError.transport
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        let refreshed: AuthTokens
        do {
            refreshed = try await task.value
        } catch APIError.authenticationExpired {
            await expireAuthentication()
            throw APIError.authenticationExpired
        }
        try tokenStore.save(refreshed)
        // The profile rides on the tokens, so a refresh is also how a name
        // edited on another device reaches this one.
        await sessionRefreshed(refreshed)
        return refreshed
    }

    private func expireAuthentication() async {
        try? tokenStore.clear()
        await authenticationExpired()
    }

    private func encoded<Body>(_ body: Body) throws -> Data
    where Body: Encodable {
        do {
            return try RemoteContractJSON.encode(body)
        } catch {
            throw APIError.encoding
        }
    }

    private func makeRequest(
        path: String,
        method: HTTPMethod,
        payload: Payload,
        accessToken: String?
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw APIError.invalidBaseURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            UUID().uuidString.lowercased(),
            forHTTPHeaderField: "X-Request-ID"
        )
        if let tunnelAccessKey {
            request.setValue(
                tunnelAccessKey,
                forHTTPHeaderField: "X-Ladle-Tunnel-Key"
            )
            request.setValue(
                "true",
                forHTTPHeaderField: "ngrok-skip-browser-warning"
            )
        }
        if let accessToken {
            request.setValue(
                "Bearer \(accessToken)",
                forHTTPHeaderField: "Authorization"
            )
        }
        switch payload {
        case .empty:
            break
        case let .json(data):
            request.httpBody = data
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
        case let .raw(data, contentType):
            request.httpBody = data
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func authorizedRequest(
        path: String,
        method: HTTPMethod,
        payload: Payload,
        accessToken: String?,
        appAttestPurpose: AppAttestPurpose?
    ) async throws -> URLRequest {
        let request = try makeRequest(
            path: path,
            method: method,
            payload: payload,
            accessToken: accessToken
        )
        guard let appAttestPurpose, let appAttester else {
            return request
        }
        return try await appAttester.authorize(
            request,
            purpose: appAttestPurpose
        )
    }

    private func perform(
        _ request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, rawResponse) = try await session.data(for: request)
            guard let response = rawResponse as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            return (data, response)
        } catch let error as APIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // URLSession reports a cooperatively cancelled request as
            // URLError(.cancelled), not CancellationError. Folding both
            // into APIError.transport made ordinary navigation-driven
            // cancellation read as "You're offline" and left every
            // downstream `catch is CancellationError` unreachable.
            throw CancellationError()
        } catch {
            throw APIError.transport
        }
    }

    private func decode<Response>(
        _: Response.Type,
        data: Data,
        response: HTTPURLResponse
    ) throws -> Response
    where Response: Decodable {
        guard (200 ..< 300).contains(response.statusCode) else {
            do {
                let envelope = try RemoteContractJSON.decoder().decode(
                    RemoteErrorEnvelope.self,
                    from: data
                )
                throw APIError.remote(envelope.error)
            } catch let error as APIError {
                throw error
            } catch {
                throw APIError.invalidResponse
            }
        }
        do {
            return try RemoteContractJSON.decoder().decode(
                Response.self,
                from: data
            )
        } catch {
            throw APIError.decoding
        }
    }

    private func validateEmptyResponse(
        data: Data,
        response: HTTPURLResponse
    ) throws {
        guard (200 ..< 300).contains(response.statusCode) else {
            if response.statusCode == 401 {
                throw APIError.authenticationExpired
            }
            if let envelope = try? RemoteContractJSON.decoder().decode(
                RemoteErrorEnvelope.self,
                from: data
            ) {
                throw APIError.remote(envelope.error)
            }
            throw APIError.invalidResponse
        }
    }

    private static func decodeTokens(
        data: Data,
        response: HTTPURLResponse
    ) throws -> AuthTokens {
        guard (200 ..< 300).contains(response.statusCode) else {
            if response.statusCode == 401 {
                throw APIError.authenticationExpired
            }
            if let envelope = try? RemoteContractJSON.decoder().decode(
                RemoteErrorEnvelope.self,
                from: data
            ) {
                throw APIError.remote(envelope.error)
            }
            throw APIError.refreshUnavailable
        }
        do {
            return try RemoteContractJSON.decoder().decode(
                AuthTokens.self,
                from: data
            )
        } catch {
            throw APIError.decoding
        }
    }
}
