// These fixtures exercise the production reader and export renderer with
// raster images, rather than mocking the barcode detector.
let context = CIContext(options: [.useSoftwareRenderer: true])
var checks = 0

func expect(_ condition: Bool, _ message: String) {
    precondition(condition, message)
    checks += 1
}

func raster(_ image: CIImage) -> CIImage {
    CIImage(cgImage: context.createCGImage(image, from: image.extent)!)
}

func qr(_ value: String) -> CIImage {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(value.utf8)
    filter.correctionLevel = "L"
    return raster(xauXatQRCodeExportImage(filter.outputImage!))
}

func expectError(_ image: CIImage, _ expected: XauXatQRCodeImageError) {
    do {
        _ = try xauXatReadQRCode(in: image)
        preconditionFailure("An invalid QR image was accepted")
    } catch let error as XauXatQRCodeImageError {
        expect(String(describing: error) == String(describing: expected), "Expected the specific QR image error")
    } catch {
        preconditionFailure("Unexpected image reader error")
    }
}

let value = "simplex:/invitation?xauxat-invite=test_fixture_only#v=1&data=AbC_09-%2F%3D"
let code = qr(value)
expect(try xauXatReadQRCode(in: code) == value, "Exported QR preserves its complete payload")
expect(code.extent.width <= 1024 && code.extent.height <= 1024, "Shared image has a bounded size")

for orientation in [Int32(1), 3, 6, 8] {
    expect(try xauXatReadQRCode(in: raster(code.oriented(forExifOrientation: orientation))) == value,
               "Read a rotated photo without changing its payload")
}

let background = CIImage(color: CIColor(red: 0.65, green: 0.65, blue: 0.65))
    .cropped(to: CGRect(x: 0, y: 0, width: 1200, height: 1000))
let inset = code.transformed(by: CGAffineTransform(scaleX: 0.55, y: 0.55))
    .transformed(by: CGAffineTransform(translationX: 130, y: 210))
let photo = raster(inset.composited(over: background).cropped(to: background.extent))
expect(try xauXatReadQRCode(in: photo) == value, "Read a code inside a larger photo")

let jpeg = NSMutableData()
let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.createCGImage(photo, from: photo.extent)!,
                          [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
expect(CGImageDestinationFinalize(destination), "JPEG fixture was written")
expect(try xauXatReadQRCode(in: CIImage(data: jpeg as Data)!) == value, "Read a saved JPEG photo")

let dense = "simplex:/invitation?xauxat-invite=" + String(repeating: "Ab0_9-", count: 350)
expect(try xauXatReadQRCode(in: qr(dense)) == dense, "Read a dense invite without truncating its payload")

let canvas = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1000, height: 500))
let left = code.transformed(by: CGAffineTransform(scaleX: 0.38, y: 0.38))
    .transformed(by: CGAffineTransform(translationX: 20, y: 40))
let other = qr("another_invitation_test_fixture_only")
    .transformed(by: CGAffineTransform(scaleX: 0.38, y: 0.38))
    .transformed(by: CGAffineTransform(translationX: 550, y: 40))
expectError(raster(left.composited(over: other.composited(over: canvas)).cropped(to: canvas.extent)), .multipleCodes)
expectError(raster(canvas), .noCode)

let duplicate = code.transformed(by: CGAffineTransform(scaleX: 0.38, y: 0.38))
    .transformed(by: CGAffineTransform(translationX: 550, y: 40))
let repeated = raster(left.composited(over: duplicate.composited(over: canvas)).cropped(to: canvas.extent))
expect(try xauXatReadQRCode(in: repeated) == value, "Repeated copies of the same QR are unambiguous")

let delivery = PhotoDelivery()
delivery.photoResult = .success(value)
delivery.deliver()
expect(delivery.values.isEmpty, "A result cannot present a connection while the photo picker is open")
delivery.photoLibraryDismissed = true
delivery.readingPhoto = true
delivery.deliver()
expect(delivery.values.isEmpty, "Dismissal cannot deliver an unfinished read")
delivery.readingPhoto = false
delivery.deliver()
expect(delivery.values == [value], "Deliver a decoded photo after dismissal")
delivery.deliver()
expect(delivery.values == [value], "Deliver each photo only once")
delivery.photoLibraryDismissed = false
delivery.photoResult = .success("second_fixture")
delivery.deliver()
expect(delivery.values.count == 1, "A fast decode still waits for dismissal")
delivery.photoLibraryDismissed = true
delivery.deliver()
expect(delivery.values.last == "second_fixture", "Dismissal releases an already decoded image")
delivery.photoResult = .failure(XauXatQRCodeImageError.noCode)
delivery.deliver()
expect(delivery.failures == 1, "An unreadable photo uses the shared error callback")
delivery.deliver()
expect(delivery.failures == 1, "Cancellation or an empty result never retries the old image")

print("\(checks) QR image, export and photo-delivery checks passed.")
