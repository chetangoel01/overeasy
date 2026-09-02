import SwiftUI
import UIKit

/// The system camera, for the one photo Overeasy ever takes.
///
/// `UIImagePickerController` rather than anything newer because this is the
/// whole requirement: one still, from the front or back camera, handed back
/// as a `UIImage`. It is also the only camera SwiftUI has — there is no
/// first-party capture view — so the wrapper is not a shortcut around one.
struct CameraPhotoPicker: UIViewControllerRepresentable {
    /// False on every simulator, which is why "Take Photo" is absent from the
    /// menu in the UI tests and the captures rather than failing in them.
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraDevice = .front
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _: UIImagePickerController,
        context _: Context
    ) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: { dismiss() })
    }

    final class Coordinator: NSObject,
        UIImagePickerControllerDelegate,
        UINavigationControllerDelegate
    {
        private let onCapture: (UIImage) -> Void
        private let dismiss: () -> Void

        init(
            onCapture: @escaping (UIImage) -> Void,
            dismiss: @escaping () -> Void
        ) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func imagePickerController(
            _: UIImagePickerController,
            didFinishPickingMediaWithInfo info:
                [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_: UIImagePickerController) {
            dismiss()
        }
    }
}
