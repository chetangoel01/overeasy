import LadleCore

enum APIError: Error, Equatable, Sendable {
    case invalidBaseURL
    case invalidResponse
    case transport
    case encoding
    case decoding
    case missingAuthentication
    case refreshUnavailable
    case authenticationExpired
    case remote(RemoteErrorDTO)
}

enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}
