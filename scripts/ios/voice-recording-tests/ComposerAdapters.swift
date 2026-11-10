import SwiftUI

// Non-audio services used by the production composer. The actual body, action
// branching, voice touch surface and recording callbacks are compiled unchanged.
enum UploadContent {
    case simpleImage(image: UIImage)
    case animatedImage(image: UIImage)
    static func loadFromURL(url: URL) -> Self? { nil }
}
struct FixtureTimePreference { func get() -> Int? { nil } }
let customDisappearingMessageTimeDefault = FixtureTimePreference()

// Media/emoji services are outside these recording tests. The UITextView,
// its focus callbacks, intrinsic sizing and keyboard lifecycle are production.
func isRightToLeft(_ text: String) -> Bool { false }
func isShortEmoji(_ text: String) -> Bool { false }
let largeEmojiUIFont = UIFont.systemFont(ofSize: 48)
let mediumEmojiUIFont = UIFont.systemFont(ofSize: 36)
extension UIImage {
    convenience init(gifData: Data) throws { throw CocoaError(.fileReadUnsupportedScheme) }
}
