import SwiftUI
import UIKit

// The simulator has no camera. Deliver a deterministic image at the same
// boundary as UIImagePickerController's Use Photo callback: assign and dismiss
// in one event. The picker/editor presentation below is production SwiftUI.
func fixtureImage() -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 1600)).image { context in
        UIColor.systemRed.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1600))
        UIColor.systemGreen.setFill()
        context.fill(CGRect(x: 600, y: 0, width: 600, height: 800))
        UIColor.systemBlue.setFill()
        context.fill(CGRect(x: 0, y: 800, width: 600, height: 800))
        UIColor.systemYellow.setFill()
        context.fill(CGRect(x: 600, y: 800, width: 600, height: 800))
    }
}

struct CameraImagePicker: View {
    @Environment(\.presentationMode) private var presentationMode
    @Binding var image: UIImage?

    var body: some View {
        VStack {
            Text("Camera fixture")
            Button("Use Photo") {
                image = fixtureImage()
                presentationMode.wrappedValue.dismiss()
            }
            .accessibilityIdentifier("source.use")
            Button("Cancel") { presentationMode.wrappedValue.dismiss() }
                .accessibilityIdentifier("source.cancel")
        }
        .buttonStyle(.borderedProminent)
    }
}

struct LibraryImagePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var image: UIImage?
    var didFinishPicking: (Bool) async -> Void

    var body: some View {
        VStack {
            Button("Select image") {
                Task {
                    await didFinishPicking(true)
                    image = fixtureImage()
                }
            }
            .accessibilityIdentifier("source.use")
            Button("Deliver after dismissal") {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    image = fixtureImage()
                }
            }
            .accessibilityIdentifier("source.late")
            Button("Cancel") { Task { await didFinishPicking(false) } }
                .accessibilityIdentifier("source.cancel")
        }
        .buttonStyle(.borderedProminent)
    }
}

struct Harness: View {
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var image: UIImage?
    @State private var saved: UIImage?
    @State private var saveCount = 0

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Button("Take picture") { showCamera = true }
                    .accessibilityIdentifier("profile.camera")
                Button("Choose from library") { showLibrary = true }
                    .accessibilityIdentifier("profile.library")
                Button("Paste image") { image = fixtureImage() }
                    .accessibilityIdentifier("profile.paste")
                Text("Saved \(saveCount)").accessibilityIdentifier("profile.saved")
                if let saved {
                    Image(uiImage: saved).resizable().frame(width: 128, height: 128)
                        .accessibilityLabel("Saved avatar")
                        .accessibilityIdentifier("profile.avatar")
                }
            }
            .navigationBarHidden(true)
            .modifier(XauXatAvatarPicker(
                showCamera: $showCamera, showLibrary: $showLibrary, image: $image
            ) { cropped in
                // Confirm that the actual crop also survives the JPEG round trip.
                guard cropped.size.width == cropped.size.height,
                      let data = cropped.jpegData(compressionQuality: 0.85),
                      let decoded = UIImage(data: data) else { return }
                saved = decoded
                saveCount += 1
            })
        }
        .navigationViewStyle(.stack)
    }
}

@main
struct AvatarHarnessApp: App {
    var body: some Scene {
        WindowGroup {
            Harness()
                .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("large-text")
                    ? .accessibility5 : .large)
        }
    }
}
