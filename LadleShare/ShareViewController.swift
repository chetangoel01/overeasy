import LadleCore
import SwiftUI
import UIKit

final class ShareViewController: UIViewController {
    private let extractor = ShareURLExtractor()
    private var hostingController:
        UIHostingController<ShareConfirmationView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        render(state: .loading)

        Task {
            await handleShare()
        }
    }

    private func handleShare() async {
        let items = extensionContext?.inputItems.compactMap {
            $0 as? NSExtensionItem
        } ?? []

        guard let url = await extractor.firstSupportedURL(in: items) else {
            render(
                state: .failure(
                    message:
                        "Ladle couldn’t find an HTTP or HTTPS link in this share."
                )
            )
            return
        }

        do {
            let queue = try makeQueue()
            try queue.enqueue(
                SharedImportEnvelope(sourceURL: url)
            )
            render(
                state: .success(
                    sourceName: sourceName(for: url)
                )
            )

            try? await ContinuousClock().sleep(
                for: .milliseconds(850)
            )
            extensionContext?.completeRequest(
                returningItems: [],
                completionHandler: nil
            )
        } catch {
            render(
                state: .failure(
                    message:
                        "The link is intact, but Ladle couldn’t save it yet. Please try again."
                )
            )
        }
    }

    private func makeQueue() throws -> SharedImportQueue {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier:
                SharedImportQueue.appGroupIdentifier
        ) else {
            throw ShareHandlingError.appGroupUnavailable
        }
        return SharedImportQueue(
            directoryURL: containerURL.appendingPathComponent(
                SharedImportQueue.appGroupDirectoryName,
                isDirectory: true
            )
        )
    }

    private func render(state: ShareConfirmationState) {
        let rootView = ShareConfirmationView(
            state: state,
            close: { [weak self] in
                self?.extensionContext?.completeRequest(
                    returningItems: [],
                    completionHandler: nil
                )
            }
        )

        if let hostingController {
            hostingController.rootView = rootView
            return
        }

        let hostingController = UIHostingController(
            rootView: rootView
        )
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints =
            false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(
                equalTo: view.leadingAnchor
            ),
            hostingController.view.trailingAnchor.constraint(
                equalTo: view.trailingAnchor
            ),
            hostingController.view.topAnchor.constraint(
                equalTo: view.topAnchor
            ),
            hostingController.view.bottomAnchor.constraint(
                equalTo: view.bottomAnchor
            ),
        ])
        hostingController.didMove(toParent: self)
        self.hostingController = hostingController
    }

    private func sourceName(for url: URL) -> String {
        let host = url.host?.lowercased() ?? "Shared link"
        return host.hasPrefix("www.")
            ? String(host.dropFirst(4))
            : host
    }
}

private enum ShareHandlingError: Error {
    case appGroupUnavailable
}
