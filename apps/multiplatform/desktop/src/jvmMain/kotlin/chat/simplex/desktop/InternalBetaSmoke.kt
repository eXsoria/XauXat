package chat.simplex.desktop

import chat.simplex.common.model.API
import chat.simplex.common.model.CC
import chat.simplex.common.model.CR
import chat.simplex.common.model.Profile
import chat.simplex.common.model.RemoteCtrlAddress
import chat.simplex.common.model.json
import chat.simplex.common.platform.ChatCtrl
import chat.simplex.common.platform.chatCloseStore
import chat.simplex.common.platform.chatMigrateInit
import chat.simplex.common.platform.chatRecvMsgWait
import chat.simplex.common.platform.chatSendCmdRetry
import chat.simplex.common.platform.chatSendRemoteCmdRetry
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.serialization.decodeFromString

/** Two disposable native profiles exercise the same remote protocol used by mobile/CLI.
 * No chat networking is started, and the controller binds only to loopback.
 */
internal fun verifyInternalBetaRemoteAccess(dir: File, desktop: ChatCtrl) {
  val migrated = chatMigrateInit(File(dir, "controlled").absolutePath, "internal-beta-test-key", "yesUp")
  check((migrated[0] as String).contains("\"type\":\"ok\"")) { "Controlled test database failed to migrate" }
  val controlled = migrated[1] as Long
  check(controlled != 0L)
  try {
    configureSmokePaths(desktop, File(dir, "desktop-files"))
    configureSmokePaths(controlled, File(dir, "controlled-files"))
    check(smokeCommand(desktop, CC.SetLocalDeviceName("CI Desktop")) is CR.CmdOk)
    check(smokeCommand(controlled, CC.SetLocalDeviceName("CI Controlled")) is CR.CmdOk)
    val profile = Profile(displayName = "CIRemote", fullName = "", shortDescr = null)
    check(smokeCommand(controlled, CC.CreateActiveUser(profile, false)) is CR.ActiveUser)
    var storedHostId: Long? = null
    repeat(2) {
      val started = smokeCommand(desktop, CC.StartRemoteHost(storedHostId, false, RemoteCtrlAddress("127.0.0.1", "lo"), null))
      check(started is CR.RemoteHostStarted)
      check(started.localAddrs.first().address == "127.0.0.1") { "Remote smoke must bind to loopback" }
      check(smokeCommand(controlled, CC.ConnectRemoteCtrl(started.invitation)) is CR.RemoteCtrlConnecting)
      val desktopCode = awaitSmokeEvent<CR.RemoteHostSessionCode>(desktop).sessionCode
      val controlledCode = awaitSmokeEvent<CR.RemoteCtrlSessionCode>(controlled).sessionCode
      check(desktopCode == controlledCode) { "Remote verification codes disagree" }
      check(smokeCommand(controlled, CC.VerifyRemoteCtrlSession(controlledCode)) is CR.RemoteCtrlConnected)
      val connected = awaitSmokeEvent<CR.RemoteHostConnected>(desktop)
      val hostId = connected.remoteHost.remoteHostId
      check(storedHostId == null || storedHostId == hostId) { "Reconnect changed the paired host" }
      storedHostId = hostId
      val remote = json.decodeFromString<API>(chatSendRemoteCmdRetry(desktop, hostId.toInt(), CC.ListUsers().cmdString, 0)).result
      check(remote is CR.UsersList && remote.users.single().user.profile.displayName == "CIRemote") {
        "Remote command did not return the controlled profile"
      }
      val local = smokeCommand(desktop, CC.ListUsers())
      check(local is CR.UsersList && local.users.isEmpty()) { "Remote profile leaked into the local profile list" }
      check(smokeCommand(controlled, CC.StopRemoteCtrl()) is CR.CmdOk)
      check(awaitSmokeEvent<CR.RemoteHostStopped>(desktop).remoteHostId_ == hostId)
    }
    println("XAUXAT_LOOPBACK_REMOTE_PAIR_VERIFY_QUERY_DISCONNECT_RECONNECT_OK")
  } finally {
    runCatching { smokeCommand(controlled, CC.StopRemoteCtrl()) }
    chatCloseStore(controlled)
  }
}

private fun configureSmokePaths(ctrl: ChatCtrl, dir: File) {
  val paths = listOf("files", "tmp", "assets", "remote_hosts").map { File(dir, it).absolutePath }
  check(smokeCommand(ctrl, CC.ApiSetAppFilePaths(paths[0], paths[1], paths[2], paths[3])) is CR.CmdOk)
}

private fun smokeCommand(ctrl: ChatCtrl, command: CC): CR {
  val response = json.decodeFromString<API>(chatSendCmdRetry(ctrl, command.cmdString, 0))
  return response.result ?: error("Native smoke command ${command.cmdType} failed: ${response.responseType}")
}

private inline fun <reified T : CR> awaitSmokeEvent(ctrl: ChatCtrl): T {
  val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
  while (System.nanoTime() < deadline) {
    val raw = chatRecvMsgWait(ctrl, 1_000_000)
    if (raw.isNotEmpty()) {
      val response = json.decodeFromString<API>(raw)
      val event = response.result
      if (event is T) return event
      check(response !is API.Error) { "Native smoke event failed: ${response.responseType}" }
    }
  }
  error("Timed out waiting for ${T::class.simpleName}")
}
