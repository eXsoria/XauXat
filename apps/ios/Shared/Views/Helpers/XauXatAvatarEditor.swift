import SwiftUI
import UIKit

struct XauXatAvatarEditor: View {
    let image: UIImage
    let onCancel: () -> Void
    let onConfirm: (UIImage) -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let cropSize: CGFloat = 300

    var body: some View {
        NavigationView {
            GeometryReader { geometry in
                let baseScale = minimumScale

                ZStack {
                    Color.black
                        .ignoresSafeArea()

                    Image(uiImage: image)
                        .resizable()
                        .frame(
                            width: image.size.width * baseScale,
                            height: image.size.height * baseScale
                        )
                        .scaleEffect(scale)
                        .offset(offset)
                        .contentShape(Rectangle())
                        .gesture(dragGesture)
                        .simultaneousGesture(magnificationGesture)

                    avatarMask
                        .allowsHitTesting(false)
                }
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height
                )
            }
            .navigationTitle("Edit photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Photo") {
                        if let result = renderCrop() {
                            onConfirm(result)
                        }
                    }
                    .font(.system(size: 17, weight: .semibold))
                }
            }
            .navigationViewStyle(.stack)
        }
    }

    private var minimumScale: CGFloat {
        max(
            cropSize / image.size.width,
            cropSize / image.size.height
        )
    }

    private var displayedSize: CGSize {
        CGSize(
            width: image.size.width * minimumScale * scale,
            height: image.size.height * minimumScale * scale
        )
    }

    private var avatarMask: some View {
        ZStack {
            Color.black.opacity(0.58)

            Circle()
                .frame(width: cropSize, height: cropSize)
                .blendMode(.destinationOut)

            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
                .frame(width: cropSize, height: cropSize)
        }
        .compositingGroup()
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = clampedOffset(
                    CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    )
                )
            }
            .onEnded { _ in
                offset = clampedOffset(offset)
                lastOffset = offset
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = max(1, min(lastScale * value, 5))
                offset = clampedOffset(offset)
            }
            .onEnded { _ in
                scale = max(1, min(scale, 5))
                lastScale = scale
                offset = clampedOffset(offset)
                lastOffset = offset
            }
    }

    private func clampedOffset(_ proposed: CGSize) -> CGSize {
        let size = displayedSize

        let maxX = max(0, (size.width - cropSize) / 2)
        let maxY = max(0, (size.height - cropSize) / 2)

        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    private func renderCrop() -> UIImage? {
        let normalized = normalizedImage(image)

        let base = max(
            cropSize / normalized.size.width,
            cropSize / normalized.size.height
        )

        let totalScale = base * scale

        let visibleOriginX =
            (normalized.size.width * totalScale - cropSize) / 2 - offset.width

        let visibleOriginY =
            (normalized.size.height * totalScale - cropSize) / 2 - offset.height

        let cropRect = CGRect(
            x: visibleOriginX / totalScale,
            y: visibleOriginY / totalScale,
            width: cropSize / totalScale,
            height: cropSize / totalScale
        )

        guard let cgImage = normalized.cgImage else {
            return nil
        }

        let pixelScaleX = CGFloat(cgImage.width) / normalized.size.width
        let pixelScaleY = CGFloat(cgImage.height) / normalized.size.height

        let pixelRect = CGRect(
            x: cropRect.origin.x * pixelScaleX,
            y: cropRect.origin.y * pixelScaleY,
            width: cropRect.width * pixelScaleX,
            height: cropRect.height * pixelScaleY
        )
        .integral
        .intersection(
            CGRect(
                x: 0,
                y: 0,
                width: cgImage.width,
                height: cgImage.height
            )
        )

        guard
            pixelRect.width > 0,
            pixelRect.height > 0,
            let cropped = cgImage.cropping(to: pixelRect)
        else {
            return nil
        }

        return UIImage(
            cgImage: cropped,
            scale: normalized.scale,
            orientation: .up
        )
    }

    private func normalizedImage(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up {
            return image
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1

        return UIGraphicsImageRenderer(
            size: image.size,
            format: format
        ).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
