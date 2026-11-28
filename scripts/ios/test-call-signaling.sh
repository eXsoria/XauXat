#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT

# Compile the same buffer used by WebRTC, substituting only the candidate payload.
client="$root/apps/ios/Shared/Views/Call/WebRTCClient.swift"
{
  echo 'import Foundation'
  echo 'typealias RTCIceCandidate = Int'
  sed -n '/^    final class IceCandidates {/,/^    }$/p' "$client"
} > "$temp/IceCandidates.swift"
{
  echo 'import Foundation'
  echo 'final class Client {'
  echo 'struct Call { let iceCandidates: IceCandidates }'
  echo 'var activeCall: Call?'
  echo 'var sent: [String] = []'
  echo 'func sendCallResponse(_ message: Message) async { if case let .ice(batch) = message.resp { sent.append(batch) } }'
  sed -n '/^    func sendRemainingIceCandidates(/,/^    }$/p' "$client"
  echo '}'
} > "$temp/Client.swift"
controller="$root/apps/ios/Shared/Views/Call/CallController.swift"
{
  echo 'import Foundation'
  echo 'final class Controller {'
  echo 'var fulfillOnConnect: CXAnswerCallAction?'
  echo 'var pendingPushes: [UUID: Date] = [:]'
  echo 'let callManager = Manager()'
  echo 'var shouldSuspendChat = false'
  echo '@MainActor'
  sed -n '/^    private func waitUntilChatStarted(/,/^    }$/p' "$controller" | sed 's/private func/func/'
  for method in 'private func canAnswer' 'private func finishAnswer' 'func provider(_ provider: CXProvider, timedOutPerforming'; do
    sed -n "/^    ${method}/,/^    }$/p" "$controller" | sed 's/private func/func/; /logger.debug/d'
  done
  echo '}'
} > "$temp/Controller.swift"
api="$root/apps/ios/Shared/Model/SimpleXAPI.swift"
{
  echo 'import Foundation'
  sed -n '/^public struct RcvCallInvitation: Decodable {/,/^}$/p' "$root/apps/ios/SimpleXChat/CallTypes.swift"
  sed -n '/^extension RcvCallInvitation {/,/^}$/p' "$root/apps/ios/Shared/Views/Call/CallManager.swift"
  sed -n '/^func refreshCallInvitations()/,/^}$/p; /^private func callsByChat(/,/^}$/p' "$api"
  echo '@MainActor'
  sed -n '/^func activateCall(/,/^}$/p' "$api" | sed '/logger\./d'
  echo '@MainActor struct BannerFixture { let m = ChatModel.shared; let cc = CallController.shared'
  sed -n '/^    private func answer(_ invitation:/,/^    }$/p' "$root/apps/ios/Shared/Views/Call/IncomingCallView.swift" | sed 's/private func/func/'
  echo '}'
  echo 'struct ModeFixture { var callUUID: String?'
  sed -n '/^    var usesCallKit: Bool {/,/^    }$/p' "$root/apps/ios/Shared/Views/Call/WebRTC.swift"
  echo '}'
  echo 'extension CallController {'
  sed -n '/^    func presentIncomingCallInApp(/,/^    }$/p' "$controller"
  sed -n '/^    static func alreadyReported(/,/^    }$/p; /^    static func allowsInAppFallback(/,/^    }$/p' "$controller"
  echo '}'
} > "$temp/Invitations.swift"
call_view="$root/apps/ios/Shared/Views/Call/ActiveCallView.swift"
{
  echo 'import Foundation'
  sed -n '/^actor WebRTCCommandProcessor {/,/^}$/p' "$root/apps/ios/Shared/Views/Call/WebRTC.swift"
  echo 'extension Active {'
  sed -n '/^    func updateMicrophonePermission(/,/^    }$/p' "$root/apps/ios/Shared/Views/Call/WebRTC.swift"
  echo '@MainActor'
  sed -n '/^    func attachWebRTC()/,/^    }$/p; /^    func finishWebRTC()/,/^    }$/p' "$call_view"
  # Use the real response ownership gate; only the payload consumer is a fixture.
  echo '@MainActor'
  sed -n '/^    private func processRtcMessage(/,/^            let call = self/p' "$call_view" | sed '/let call = self/d; s/private func/func/; s/WVAPIMessage/String/'
  echo '            _ = client'
  echo '            offers += 1'
  echo '        }'
  echo '    }'
  echo '}'
  echo 'extension Manager {'
  sed -n '/^    func answerIncomingCall(invitation:/,/^    }$/p; /^    func startOutgoingCall(/,/^    }$/p; /^    func enableMedia(/,/^    }$/p' "$root/apps/ios/Shared/Views/Call/CallManager.swift" | sed '/logger.debug/d'
  echo '}'
  echo 'extension WebRTCClient {'
  sed -n '/^    private func claimAudioSession()/,/^    }$/p; /^    static func callKitAudioChanged(/,/^    }$/p; /^    private func releaseAppAudioActivation()/,/^    }$/p; /^    func audioSessionToDefaults()/,/^    }$/p; /^    private func createAudioTrack()/,/^    }$/p; /^    func setCaptureAllowed(/,/^    }$/p; /^    func stopSendingAudio()/,/^    }$/p' "$client" | sed 's/private func/func/; s/catch let error {/catch {/; /logger\./d'
  echo '}'
} > "$temp/Headless.swift"
{
  echo 'import Foundation'
  echo 'extension AppDelegate {'
  sed -n '/^    func application(_ application: UIApplication, didFinishLaunchingWithOptions/,/^    }$/p' "$root/apps/ios/Shared/AppDelegate.swift" | sed '/logger.debug/d'
  echo '}'
  echo 'final class CallController: NSObject {'
  echo 'static let shared = CallController()'
  echo 'let provider = CXProvider(); let callManager = Manager(); let registry = PKPushRegistry(); var shouldSuspendChat = false'
  sed -n '/^    private var pendingPushes:/p; /^    private var lastNativeCallUUID:/p; /^    override init()/,/^    }$/p' "$controller"
  sed -n '/^    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith/,/^    }$/p' "$controller" | sed '/logger.debug/d'
  sed -n '/^    func provider(_ provider: CXProvider, perform action: CXEndCallAction)/,/^    }$/p' "$controller" | sed '/logger.debug/d'
  echo '@MainActor'
  sed -n '/^    private func prepareChatForPush(/,/^    }$/p' "$controller" | sed '/logger.error/d'
  sed -n '/^    private func finishAnswer(/,/^    }$/p' "$controller" | sed 's/private func/func/'
  echo '}'
} > "$temp/ColdPush.swift"
swiftc -swift-version 5 -parse-as-library "$temp/ColdPush.swift" \
  "$root/scripts/ios/call-audio-tests/ColdPushTests.swift" -o "$temp/cold-push"
"$temp/cold-push"
swiftc -swift-version 5 -parse-as-library "$temp/IceCandidates.swift" \
  "$temp/Headless.swift" "$root/scripts/ios/call-audio-tests/HeadlessTests.swift" "$temp/Controller.swift" "$temp/Client.swift" "$temp/Invitations.swift" "$root/scripts/ios/call-audio-tests/InvitationTests.swift" "$root/scripts/ios/call-audio-tests/SignalingTests.swift" -o "$temp/test"
"$temp/test"


# Force WebRTC closure to finish before the native end delegate runs.
python3 "$root/scripts/ios/call-audio-tests/make-transport-close-test.py" \
  "$root/apps/ios/Shared/Views/Call" "$temp/TransportClose.swift"
swiftc -swift-version 5 -parse-as-library "$temp/TransportClose.swift" -o "$temp/transport-close"
"$temp/transport-close"
