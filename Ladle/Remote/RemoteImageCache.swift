import Foundation
import LadleCore

enum RemoteImageCacheError: Error, Equatable {
    case invalidResponse
    case unavailable(statusCode: Int)
    case refreshedImageMissing
}

/// Which server object can re-issue a fresh signed URL for an image
/// whose stored URL has expired.
enum RemoteImageOwner: Equatable, Sendable {
    /// A recipe saved in the caller's own library.
    case recipe(id: UUID)
    /// A Discover source video, which is not a recipe in the caller's
    /// library.
    case discoverSource(id: UUID)
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
        owner: RemoteImageOwner,
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
                owner: owner,
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
        owner: RemoteImageOwner,
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
            let retry = try await fetch(
                refreshedImageURL(owner: owner, image: image, api: api),
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

    private static func refreshedImageURL(
        owner: RemoteImageOwner,
        image: RemoteRecipeImageDTO,
        api: APIClient
    ) async throws -> URL {
        switch owner {
        case let .recipe(id):
            let refreshed: RemoteRecipeDTO = try await api.request(
                path: "/v1/recipes/\(id.uuidString)"
            )
            guard
                let refreshedImage = refreshed.images.first(
                    where: { $0.id == image.id }
                )
            else {
                throw RemoteImageCacheError.refreshedImageMissing
            }
            return refreshedImage.remoteURL
        case let .discoverSource(id):
            // A Discover source is not a recipe in the caller's library,
            // so only the Discover detail can re-sign its thumbnail —
            // and that detail mints the image id server-side
            // (uuid5(source, "discover-thumbnail")) while the feed hands
            // the client no image id at all, so the single refreshed
            // thumbnail is taken by position, not by id.
            let refreshed: RemoteRecipeDTO = try await api.request(
                path: DiscoverAPI.detailPath(sourceID: id)
            )
            guard let refreshedImage = refreshed.images.first else {
                throw RemoteImageCacheError.refreshedImageMissing
            }
            return refreshedImage.remoteURL
        }
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
