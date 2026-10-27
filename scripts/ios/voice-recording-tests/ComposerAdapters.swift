import SwiftUI

// Non-audio services used by the production composer. The actual body, action
// branching, voice touch surface and recording callbacks are compiled unchanged.
struct UploadContent {}
struct FixtureTimePreference { func get() -> Int? { nil } }
let customDisappearingMessageTimeDefault = FixtureTimePreference()

struct NativeTextEditor: View {
    static let minHeight: CGFloat = 44
    @Binding var text: String
    @Binding var disableEditing: Bool
    @Binding var height: CGFloat
    @Binding var focused: Bool
    @Binding var lastUnfocusedDate: Date
    @Binding var placeholder: String
    @Binding var selectedRange: NSRange
    let onImagesAdded: ([UploadContent]) -> Void
    var body: some View {
        Text(placeholder)
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}
