import Foundation
import Vision
import Darwin

// Process liveness alone also passes when the opening animation never ends.
// A clean simulator must render the first actionable onboarding screen.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: verify-onboarding-screenshot.swift screenshot.png\n", stderr)
    exit(2)
}
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["en-US"]
request.usesLanguageCorrection = false
try VNImageRequestHandler(url: URL(fileURLWithPath: CommandLine.arguments[1])).perform([request])
let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
let text = lines.joined(separator: " ").uppercased()
print("Fresh-launch visible text: " + lines.joined(separator: " | "))
guard text.contains("CONTINUE PRIVATELY") else {
    fputs("Fresh launch did not reach the actionable onboarding screen. Inspect screenshot and startup logs.\n", stderr)
    exit(1)
}
print("Fresh simulator launch reached the actionable onboarding screen.")
