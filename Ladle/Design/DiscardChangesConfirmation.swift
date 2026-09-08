import SwiftUI
import UIKit

extension View {
    func discardChangesConfirmation(
        isPresented: Binding<Bool>, hasChanges: Bool,
        discard: @escaping () -> Void
    ) -> some View {
        alert("Discard your changes?", isPresented: isPresented) {
            Button("Discard Changes", role: .destructive, action: discard)
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your unsaved changes will be lost.")
        }
        .interactiveDismissDisabled(hasChanges)
        .background {
            DismissAttemptObserver(hasChanges: hasChanges) {
                isPresented.wrappedValue = true
            }
            .allowsHitTesting(false)
        }
    }
}

/// SwiftUI can prevent a dirty sheet's dismissal, but doesn't report the
/// attempted swipe. Observe that system callback to offer the same choice
/// as Cancel. Only a dirty form takes over the presentation delegate.
private struct DismissAttemptObserver: UIViewControllerRepresentable {
    var hasChanges: Bool
    var onAttempt: () -> Void

    func makeUIViewController(context: Context) -> Observer { Observer() }

    func updateUIViewController(_ controller: Observer, context: Context) {
        controller.hasChanges = hasChanges
        controller.onAttempt = onAttempt
        controller.updateDelegate()
    }

    static func dismantleUIViewController(_ controller: Observer, coordinator: ()) {
        controller.restoreDelegate()
    }

    final class Observer: UIViewController, UIAdaptivePresentationControllerDelegate {
        var hasChanges = false
        var onAttempt: () -> Void = {}
        private weak var observedPresentation: UIPresentationController?
        private weak var previousDelegate: (any UIAdaptivePresentationControllerDelegate)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            updateDelegate()
        }

        func updateDelegate() {
            guard hasChanges else { restoreDelegate(); return }
            var ancestor = parent
            while let controller = ancestor {
                // A pushed controller can report an inherited presenter.
                // Only the controller actually presented owns the sheet.
                if controller.presentingViewController?.presentedViewController === controller,
                   let presentation = controller.presentationController {
                    if presentation.delegate !== self {
                        observedPresentation = presentation
                        previousDelegate = presentation.delegate
                        presentation.delegate = self
                    }
                    return
                }
                ancestor = controller.parent
            }
        }

        func restoreDelegate() {
            if observedPresentation?.delegate === self {
                observedPresentation?.delegate = previousDelegate
            }
            observedPresentation = nil
            previousDelegate = nil
        }

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            !hasChanges
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            onAttempt()
        }
    }
}
