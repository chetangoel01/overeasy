import Foundation
import LadleCore

enum RemoteImageCacheError: Error, Equatable {
    case invalidResponse
    case unavailable(statusCode: Int)
    case refreshedImageMissing
}

actor RemoteImageCache {
    private let directoryURL: URL
    private let session: URLSession
    private let api: APIClient
    private var downloads: [UUID: Task<URL, Error>] = [:]

    init(
        directoryURL: URL,
        session: URLSession = .shared,
        api: APIClient
    ) {
        self.directoryURL = directoryURL
        self.session = session
        self.api = api
    }

    func localURL(
        recipeID: UUID,
        image: RemoteRecipeImageDTO
    ) async throws -> URL {
        let destination = directoryURL.appendingPathComponent(
            image.id.uuidString.lowercased(),
            isDirectory: false
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        if let download = downloads[image.id] {
            return try await download.value
        }

        let directoryURL = directoryURL
        let session = session
        let api = api
        let task = Task {
            try await Self.download(
                recipeID: recipeID,
                image: image,
                destination: destination,
                directoryURL: directoryURL,
                session: session,
                api: api
            )
        }
        downloads[image.id] = task
        defer { downloads[image.id] = nil }
        return try await task.value
    }

    private static func download(
        recipeID: UUID,
        image: RemoteRecipeImageDTO,
        destination: URL,
        directoryURL: URL,
        session: URLSession,
        api: APIClient
    ) async throws -> URL {
        let initial = try await fetch(image.remoteURL, session: session)
        let data: Data
        if (200 ..< 300).contains(initial.statusCode) {
            data = initial.data
        } else if initial.statusCode == 401 || initial.statusCode == 403 {
            let refreshed: RemoteRecipeDTO = try await api.request(
                path: "/v1/recipes/\(recipeID.uuidString)"
            )
            guard
                let refreshedImage = refreshed.images.first(
                    where: { $0.id == image.id }
                )
            else {
                throw RemoteImageCacheError.refreshedImageMissing
            }
            let retry = try await fetch(
                refreshedImage.remoteURL,
                session: session
            )
            guard (200 ..< 300).contains(retry.statusCode) else {
                throw RemoteImageCacheError.unavailable(
                    statusCode: retry.statusCode
                )
            }
            data = retry.data
        } else {
            throw RemoteImageCacheError.unavailable(
                statusCode: initial.statusCode
            )
        }

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private static func fetch(
        _ url: URL,
        session: URLSession
    ) async throws -> (data: Data, statusCode: Int) {
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse else {
            throw RemoteImageCacheError.invalidResponse
        }
        return (data, response.statusCode)
    }
}
