import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// A picture from bytes, on either platform.
func pictureImage(_ data: Data) -> Image? {
    #if canImport(UIKit)
        UIImage(data: data).map { Image(uiImage: $0) }
    #elseif canImport(AppKit)
        NSImage(data: data).map { Image(nsImage: $0) }
    #else
        nil
    #endif
}

#if os(iOS)
    import VisionKit

    /// The camera, for a meal's photo. Hands back the picture as a JPEG, or
    /// nil when the owner cancels.
    struct CameraPicker: UIViewControllerRepresentable {
        let onShot: (Data?) -> Void

        static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

        func makeUIViewController(context: Context) -> UIImagePickerController {
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.cameraCaptureMode = .photo
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

        func makeCoordinator() -> Coordinator {
            Coordinator(onShot: onShot)
        }

        @MainActor
        final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
            let onShot: (Data?) -> Void

            init(onShot: @escaping (Data?) -> Void) {
                self.onShot = onShot
            }

            func imagePickerController(
                _ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
            ) {
                let image = info[.originalImage] as? UIImage
                onShot(image?.jpegData(compressionQuality: 0.9))
            }

            func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
                onShot(nil)
            }
        }
    }

    /// The live barcode reader. Hands back the first code it reads.
    struct BarcodeScanner: UIViewControllerRepresentable {
        let onCode: (String) -> Void

        /// False in the simulator and on phones without the hardware; the
        /// number is typed instead.
        @MainActor static var isAvailable: Bool {
            DataScannerViewController.isSupported && DataScannerViewController.isAvailable
        }

        func makeUIViewController(context: Context) -> DataScannerViewController {
            let scanner = DataScannerViewController(
                recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .code128, .itf14])],
                qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                isGuidanceEnabled: true, isHighlightingEnabled: true)
            scanner.delegate = context.coordinator
            return scanner
        }

        func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
            // Only once it is on screen; before that it refuses to start.
            if !scanner.isScanning {
                try? scanner.startScanning()
            }
        }

        static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
            scanner.stopScanning()
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(onCode: onCode)
        }

        @MainActor
        final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            let onCode: (String) -> Void
            private var done = false

            init(onCode: @escaping (String) -> Void) {
                self.onCode = onCode
            }

            func dataScanner(
                _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                allItems: [RecognizedItem]
            ) {
                guard !done else { return }
                for item in addedItems {
                    if case .barcode(let barcode) = item, let value = barcode.payloadStringValue,
                        let code = FoodTyping.barcode(value)
                    {
                        done = true
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        onCode(code)
                        return
                    }
                }
            }
        }
    }
#endif
