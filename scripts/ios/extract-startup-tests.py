from pathlib import Path
import sys

root, destination = map(Path, sys.argv[1:])


def declaration(path, marker):
    source = (root / path).read_text(encoding="utf-8")
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("private func ", "func ", 1)


app_path = "apps/ios/Shared/SimpleXApp.swift"
app = (root / app_path).read_text(encoding="utf-8")
assert app.count("initializeNewInstallation()") == 3, "Fresh setup must run on appearance and foreground"
text = "import Foundation\n"
text += declaration("apps/ios/Shared/Model/SimpleXAPI.swift", "func startChat(")
text += "\n" + declaration("apps/ios/Shared/Model/SuspendChat.swift", "func initChatAndMigrate(")
text += "\n@MainActor final class StartupHarness {\n"
text += "let chatModel = ChatModel.shared\nvar scenePhase: Phase = .active\n"
text += declaration(app_path, "private func initializeNewInstallation()") + "\n}\n"
text += "\n@MainActor final class SetupHarness {\n"
text += "let chatModel = ChatModel.shared\nvar scenePhase: Phase = .active\n"
text += "var validName = true, validPIN = true, isCompleting = false, profileCreated = false\n"
text += 'var compactName = "Synthetic", pin = "123456"\n'
text += 'var focusedField: String? = "pin", errorMessage: String?\n'
text += "var notificationMode: NotificationsMode? = .off\nvar completions = 0\n"
text += "func applySimpleXOnboardingDefaults() { completions += 1; isCompleting = false }\n"
text += declaration("apps/ios/Shared/Views/XauXatHomeView.swift", "private func finishOnboarding()")
text += "\n}\n"
destination.write_text(text, encoding="utf-8")
