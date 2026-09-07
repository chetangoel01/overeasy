import Foundation
import LadleCore

/// Re-links Inbox rows that builds `20260902.1` and `20260903.1` wrote
/// without a recipe.
///
/// Those builds finished a needs-review import with
/// `ImportJob.transitioning(to: .needsReview)`, which never set
/// `currentRecipeID`, so the row named no recipe: completing the review
/// could not find the row to close, and tapping the row opened the
/// failed-import sheet for an import that had succeeded (issue #91). The
/// write is fixed; rows already on a phone are not, and the cook cannot be
/// asked to discard a row that says "Couldn't read the recipe" about a
/// recipe they can see in their library.
///
/// Nothing is ever deleted here. A row that cannot be matched with
/// confidence is left exactly as it is and reported in the result.
@MainActor
final class ImportReviewLinkRepair {
    /// The repair's own record of what it did. The app has no logging
    /// facility, so this is the log: the caller can assert on it, print it,
    /// or ignore it.
    struct Outcome: Equatable {
        var linked: [UUID] = []
        var cleared: [UUID] = []
        var skipped: [UUID] = []

        var isEmpty: Bool {
            linked.isEmpty && cleared.isEmpty && skipped.isEmpty
        }
    }

    private let repository: RecipeRepository
    private let now: () -> Date

    init(
        repository: RecipeRepository,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.now = now
    }

    /// Safe to run on every activation: it only touches a `.needsReview` job
    /// that names no recipe, and a repaired job no longer qualifies.
    @discardableResult
    func repair() throws -> Outcome {
        let jobs = try repository.fetchImportJobs()
        // `reviewRecipeID` is nil exactly when the job is awaiting review and
        // holds neither a current nor a candidate recipe, so a re-import's
        // accept/keep decision is never in this list.
        let unlinked = jobs.filter {
            $0.status == .needsReview && $0.reviewRecipeID == nil
        }
        guard !unlinked.isEmpty else {
            return Outcome()
        }

        let recipes = try repository.fetchRecipes()
        var claimed = Set(
            jobs.flatMap {
                [$0.currentRecipeID, $0.candidateRecipeID].compactMap { $0 }
            }
        )
        var outcome = Outcome()
        let date = now()

        for job in unlinked {
            guard let key = SourceVideoKey(job.sourceURL) else {
                outcome.skipped.append(job.id)
                continue
            }
            let matches = recipes.filter {
                !claimed.contains($0.id)
                    && SourceVideoKey($0.originalURL) == key
            }
            // One match is the only safe answer. None means the recipe was
            // deleted, or the link is a short one only the server can
            // resolve; several means two imports of the same video, and
            // guessing between them would put the wrong recipe behind the
            // row.
            guard matches.count == 1, let recipe = matches.first else {
                outcome.skipped.append(job.id)
                continue
            }

            let linked = try job.linkingReviewRecipe(recipe.id, at: date)
            switch recipe.reviewStatus {
            case .needsReview:
                try repository.save(linked)
                outcome.linked.append(job.id)
            case .ready:
                // The cook reviewed it already — the stranded row is all
                // that was left of the import.
                try repository.save(
                    linked.transitioning(to: .ready, at: date)
                )
                outcome.cleared.append(job.id)
            }
            claimed.insert(recipe.id)
        }
        return outcome
    }
}

/// The video a link points at.
///
/// The job holds the URL the cook pasted; the recipe holds the one the
/// server canonicalised (`SourceIdentity.canonical_url`), so comparing the
/// raw URLs mostly fails — `m.` hosts, `/reels/` for `/reel/`, `/share/`
/// prefixes and tracking queries all differ. The platform and its video id
/// survive all of that. Short links (`vm.tiktok.com`, `/t/…`) resolve only
/// server-side, so they yield no key and their rows are left alone.
struct SourceVideoKey: Hashable {
    let platform: String
    let videoID: String

    init?(_ url: URL) {
        guard let host = url.host?.lowercased() else {
            return nil
        }
        let path = url.path
        let platform: String
        let identifier: String?

        switch host {
        case "youtube.com", "www.youtube.com", "m.youtube.com":
            platform = "youtube"
            if path == "/watch" {
                identifier = URLComponents(
                    url: url,
                    resolvingAgainstBaseURL: false
                )?
                .queryItems?
                .first { $0.name == "v" }?
                .value
            } else {
                identifier = ["/shorts/", "/live/", "/embed/"]
                    .first { path.hasPrefix($0) }
                    .map { String(path.dropFirst($0.count)) }
            }
        case "youtu.be":
            platform = "youtube"
            identifier = path
        case "tiktok.com", "www.tiktok.com", "m.tiktok.com":
            platform = "tiktok"
            let parts = path.split(separator: "/")
            identifier = parts.count == 3
                && parts[0].hasPrefix("@")
                && parts[1] == "video"
                ? String(parts[2])
                : nil
        case "instagram.com", "www.instagram.com", "m.instagram.com":
            platform = "instagram"
            var parts = path.split(separator: "/")
            if parts.first == "share" {
                parts.removeFirst()
            }
            // One post is served at both /reel/ and /reels/, so the plural
            // collapses, exactly as the server's parser collapses it.
            identifier = parts.count == 2
                && ["reel", "reels", "p"].contains(String(parts[0]))
                ? String(parts[1])
                : nil
        default:
            return nil
        }

        guard let first = identifier?
            .split(separator: "/")
            .first
            .map(String.init), !first.isEmpty else {
            return nil
        }
        self.platform = platform
        videoID = first
    }
}
