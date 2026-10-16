//
//  QRCode.swift
//  SimpleX
//
//  Created by Evgeny Poberezkin on 30/01/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//
// Spec: spec/client/navigation.md

import SwiftUI
import CoreImage.CIFilterBuiltins
import SimpleXChat

enum XauXatQRCodeImageError: LocalizedError {
    case unreadableImage
    case detectorUnavailable
    case noCode
    case multipleCodes

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return NSLocalizedString("This image could not be opened. Choose another QR image.", comment: "QR image error")
        case .detectorUnavailable:
            return NSLocalizedString("The QR reader is unavailable. Please try again.", comment: "QR image error")
        case .noCode:
            return NSLocalizedString("No readable QR code was found. Choose a clearer image containing the whole QR code.", comment: "QR image error")
        case .multipleCodes:
            return NSLocalizedString("This image contains different QR codes. Choose an image containing only the code you want to scan.", comment: "QR image error")
        }
    }
}

func xauXatReadQRCode(in image: CIImage) throws -> String {
    guard let detector = CIDetector(
        ofType: CIDetectorTypeQRCode,
        context: nil,
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
    ) else { throw XauXatQRCodeImageError.detectorUnavailable }
    let strings = Set(detector.features(in: image).compactMap {
        ($0 as? CIQRCodeFeature)?.messageString
    }.filter { !$0.isEmpty })
    guard !strings.isEmpty else { throw XauXatQRCodeImageError.noCode }
    guard strings.count == 1, let string = strings.first else { throw XauXatQRCodeImageError.multipleCodes }
    return string
}

func xauXatQRCodeExportImage(_ image: CIImage) -> CIImage {
    // Keep modules on whole pixels and leave four extra white modules around
    // the code, so the shared image can be scanned after saving or resizing.
    let scale = max(1, floor(1024 / (max(image.extent.width, image.extent.height) + 8)))
    let size = CGSize(width: (image.extent.width + 8) * scale, height: (image.extent.height + 8) * scale)
    let code = image
        .transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        .transformed(by: CGAffineTransform(translationX: 4 * scale, y: 4 * scale))
    return code.composited(over: CIImage(color: .white)).cropped(to: CGRect(origin: .zero, size: size))
}

func xauXatReadQRCodePhoto(_ image: UIImage) async -> Result<String, Error> {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<String, Error> = autoreleasepool {
                Result {
                    guard let source = image.cgImage.map({ CIImage(cgImage: $0) }) ?? image.ciImage else {
                        throw XauXatQRCodeImageError.unreadableImage
                    }
                    let oriented = source.oriented(forExifOrientation: xauXatQRCodeExifOrientation(image.imageOrientation))
                    return try xauXatReadQRCode(in: oriented)
                }
            }
            continuation.resume(returning: result)
        }
    }
}

private func xauXatQRCodeExifOrientation(_ orientation: UIImage.Orientation) -> Int32 {
    switch orientation {
    case .up: return 1
    case .upMirrored: return 2
    case .down: return 3
    case .downMirrored: return 4
    case .leftMirrored: return 5
    case .right: return 6
    case .rightMirrored: return 7
    case .left: return 8
    @unknown default: return 1
    }
}

struct MutableQRCode: View {
    @Binding var uri: String
    var small: Bool = false
    var withLogo: Bool = true
    var tintColor = UIColor(red: 0.023, green: 0.176, blue: 0.337, alpha: 1)

    var body: some View {
        QRCode(uri: uri, small: small, withLogo: withLogo, tintColor: tintColor)
            .id("simplex-qrcode-view-for-\(uri)")
    }
}

struct SimpleXCreatedLinkQRCode: View {
    let link: CreatedConnLink
    @Binding var short: Bool
    var onShare: (() -> Void)? = nil

    var body: some View {
        QRCode(uri: link.simplexChatUri(short: short), small: short && link.connShortLink != nil, onShare: onShare)
    }
}

struct SimpleXLinkQRCode: View {
    let uri: String
    var withLogo: Bool = true
    var tintColor = UIColor(red: 0.023, green: 0.176, blue: 0.337, alpha: 1)
    var onShare: (() -> Void)? = nil

    var body: some View {
        QRCode(uri: simplexChatLink(uri), small: uri.count < 200, withLogo: withLogo, tintColor: tintColor, onShare: onShare)
    }
}

private let smallQRRatio: CGFloat = 0.63

struct QRCode: View {
    let uri: String
    var small: Bool = false
    var withLogo: Bool = true
    var tintColor = UIColor(red: 0.023, green: 0.176, blue: 0.337, alpha: 1)
    var onShare: (() -> Void)? = nil
    @State private var image: UIImage? = nil
    @State private var generationFailed = false
    @State private var width: CGFloat = .infinity

    var body: some View {
        ZStack {
            if let image = image {
                qrCodeImage(image).frame(width: width, height: width)
                GeometryReader { g in
                    let w = g.size.width * (small ? smallQRRatio : 1)
                    let l = w * (small ? 0.195 : 0.16)
                    let m = w * 0.005
                    ZStack {
                        if withLogo {
                            XauXatQRCodeLogo()
                                .frame(width: l, height: l)
                                .frame(width: l + m, height: l + m)
                                .background(.white)
                                .clipShape(Circle())
                        }
                    }
                    .onAppear {
                        width = w
                    }
                    .frame(width: g.size.width, height: g.size.height)
                }
            } else if generationFailed {
                Text("QR code unavailable. Try creating a smaller invitation.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
            } else {
                Color.clear.aspectRatio(small ? 1 / smallQRRatio : 1, contentMode: .fit)
            }
        }
        .onTapGesture(perform: shareQRCodeImage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(generationFailed ? "QR code unavailable" : "QR code")
        .accessibilityHint(generationFailed ? "" : "Double-tap to share the QR code as an image.")
        .accessibilityAddTraits(generationFailed ? [] : .isButton)
        .accessibilityAction { shareQRCodeImage() }
        .task(id: uri) {
            generationFailed = false
            image = await generateImage(uri, tintColor: tintColor, errorLevel: withLogo ? "H" : (small ? "M" : "L"))
            generationFailed = image == nil
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shareQRCodeImage() {
        guard !generationFailed, let source = image?.cgImage else { return }
        let export = xauXatQRCodeExportImage(CIImage(cgImage: source))
        guard let rendered = CIContext().createCGImage(export, from: export.extent) else { return }
        var sharedImage = UIImage(cgImage: rendered)
        if withLogo {
            let size = sharedImage.size
            let logoSide = floor(size.width * (small ? 0.195 : 0.16))
            let logoSize = CGSize(width: logoSide, height: logoSide)
            let logo = XauXatQRCodeLogo()
                .frame(width: logoSide, height: logoSide)
                .makeScreenshot(nil, logoSize)
            let imageWithoutLogo = sharedImage
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            sharedImage = UIGraphicsImageRenderer(size: size, format: format).image { context in
                imageWithoutLogo.draw(in: CGRect(origin: .zero, size: size))
                let rect = CGRect(x: (size.width - logoSide) / 2, y: (size.height - logoSide) / 2, width: logoSide, height: logoSide)
                UIColor.white.setFill()
                context.cgContext.fillEllipse(in: rect.insetBy(dx: -3, dy: -3))
                logo.draw(in: rect)
            }
        }
        showShareSheet(items: [sharedImage])
        onShare?()
    }
}

private struct XauXatQRCodeLogo: View {
    private static let appIcon = loadPrimaryAppIcon()

    var body: some View {
        ZStack {
            Circle().fill(Color.black)
            if let appIcon = Self.appIcon {
                Image(uiImage: appIcon)
                    .resizable()
                    .scaledToFill()
            } else {
                XauXatQRCodeMark()
                    .fill(Color(red: 0.94, green: 0.91, blue: 0.85), style: FillStyle(eoFill: true))
                    .padding(7)
            }
        }
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private static func loadPrimaryAppIcon() -> UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String] else { return nil }
        return files.reversed().compactMap { UIImage(named: $0) }.first
    }
}

private struct XauXatQRCodeMark: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        var path = Path()
        path.move(to: point(0.17, 0.08))
        path.addLine(to: point(0.46, 0.32))
        path.addLine(to: point(0.54, 0.32))
        path.addLine(to: point(0.83, 0.08))
        path.addLine(to: point(0.94, 0.42))
        path.addLine(to: point(0.82, 0.78))
        path.addLine(to: point(0.50, 0.97))
        path.addLine(to: point(0.18, 0.78))
        path.addLine(to: point(0.06, 0.42))
        path.closeSubpath()

        path.move(to: point(0.31, 0.43))
        path.addLine(to: point(0.45, 0.54))
        path.addLine(to: point(0.35, 0.58))
        path.closeSubpath()
        path.move(to: point(0.69, 0.43))
        path.addLine(to: point(0.65, 0.58))
        path.addLine(to: point(0.55, 0.54))
        path.closeSubpath()
        return path
    }
}

private func qrCodeImage(_ image: UIImage) -> some View {
    Image(uiImage: image)
        .resizable()
        .interpolation(.none)
        .aspectRatio(1, contentMode: .fit)
        .textSelection(.enabled)
}

private func generateImage(_ uri: String, tintColor: UIColor, errorLevel: String) async -> UIImage? {
    let context = CIContext()
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(uri.utf8)
    filter.correctionLevel = errorLevel
    if let outputImage = filter.outputImage,
       let cgImage = context.createCGImage(outputImage, from: outputImage.extent) {
        return UIImage(cgImage: cgImage).replaceColor(UIColor.black, tintColor)
    }
    return nil
}

extension View {
    func makeScreenshot(_ origin: CGPoint? = nil, _ targetSize: CGSize? = nil) -> UIImage {
        let controller = UIHostingController(rootView: self.edgesIgnoringSafeArea(.all))
        let targetSize = targetSize ?? controller.view.intrinsicContentSize
        let view = controller.view
        view?.bounds = CGRect(origin: origin ?? .zero, size: targetSize)
        view?.backgroundColor = .clear
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            view?.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
    }
}

struct QRCode_Previews: PreviewProvider {
    static var previews: some View {
        QRCode(uri: "https://simplex.chat/invitation#/?v=1&smp=smp%3A%2F%2Fu2dS9sG8nMNURyZwqASV4yROM28Er0luVTx5X1CsMrU%3D%40smp4.simplex.im%2FFe5ICmvrm4wkrr6X1LTMii-lhBqLeB76%23MCowBQYDK2VuAyEAdhZZsHpuaAk3Hh1q0uNb_6hGTpuwBIrsp2z9U2T0oC0%3D&e2e=v%3D1%26x3dh%3DMEIwBQYDK2VvAzkAcz6jJk71InuxA0bOX7OUhddfB8Ov7xwQIlIDeXBRZaOntUU4brU5Y3rBzroZBdQJi0FKdtt_D7I%3D%2CMEIwBQYDK2VvAzkA-hDvk1duBi1hlOr08VWSI-Ou4JNNSQjseY69QyKm7Kgg1zZjbpGfyBqSZ2eqys6xtoV4ZtoQUXQ%3D")
    }
}
