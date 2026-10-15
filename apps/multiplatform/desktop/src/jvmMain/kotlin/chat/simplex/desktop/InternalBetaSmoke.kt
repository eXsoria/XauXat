package chat.simplex.desktop

import chat.simplex.common.model.API
import chat.simplex.common.model.CC
import chat.simplex.common.model.CR
import chat.simplex.common.model.NetCfg
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
 * The controlled core runs without subscriptions/file workers and with relay
 * traffic forced through an unavailable loopback proxy. No multicast is used.
 * Connections use a loopback invitation; the native listener uses wildcard binding.
 */
internal fun verifyInternalBetaRemoteAccess(dir: File, desktop: ChatCtrl) {
  System.getenv("XAUXAT_DESKTOP_EXTERNAL_PEER_SMOKE")?.let {
    verifyExternalSmokePeer(dir, desktop, File(it))
    return
  }
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
    // Remote-control commands require the controlled chat core to be running.
    // mainApp=false disables subscriptions, file workers and periodic relay work.
    val blockedRelayConfig = NetCfg.defaults.copy(socksProxy = "127.0.0.1:1")
    check(smokeCommand(controlled, CC.APISetNetworkConfig(blockedRelayConfig)) is CR.CmdOk)
    check(smokeCommand(controlled, CC.StartChat(mainApp = false)) is CR.ChatStarted)
    var storedHostId: Long? = null
    repeat(2) {
      val started = smokeCommand(desktop, CC.StartRemoteHost(storedHostId, false, RemoteCtrlAddress("127.0.0.1", "lo"), null))
      check(started is CR.RemoteHostStarted)
      check(started.localAddrs.first().address == "127.0.0.1") { "Remote smoke must advertise loopback" }
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
    runCatching { smokeCommand(controlled, CC.ApiStopChat()) }
    chatCloseStore(controlled)
  }
}

/** An owned external CLI peer verifies the Desktop controller across OSes.
 * The operator harness compares both codes before issuing CLI verification.
 */
private fun verifyExternalSmokePeer(dir: File, desktop: ChatCtrl, peer: File) {
  check(peer.isDirectory && peer.list().orEmpty().isEmpty()) { "External probe directory must be fresh and empty" }
  configureSmokePaths(desktop, File(dir, "desktop-files"))
  check(smokeCommand(desktop, CC.SetLocalDeviceName("XauXat Windows Probe")) is CR.CmdOk)
  var storedHostId: Long? = null
  repeat(2) { cycle ->
    val started = smokeCommand(desktop, CC.StartRemoteHost(storedHostId, false, RemoteCtrlAddress("127.0.0.1", "lo"), 12346))
    check(started is CR.RemoteHostStarted && started.localAddrs.first().address == "127.0.0.1")
    File(peer, "invitation-$cycle").writeText(started.invitation + "\n")
    val code = awaitSmokeEvent<CR.RemoteHostSessionCode>(desktop, 120).sessionCode
    File(peer, "desktop-code-$cycle").writeText(code + "\n")
    val connected = awaitSmokeEvent<CR.RemoteHostConnected>(desktop, 120)
    val hostId = connected.remoteHost.remoteHostId
    check(storedHostId == null || storedHostId == hostId)
    storedHostId = hostId
    val remote = json.decodeFromString<API>(chatSendRemoteCmdRetry(desktop, hostId.toInt(), CC.ListUsers().cmdString, 0)).result
    check(remote is CR.UsersList && remote.users.single().user.profile.displayName == "XauXatDesktopProbe")
    val local = smokeCommand(desktop, CC.ListUsers())
    check(local is CR.UsersList && local.users.isEmpty())
    File(peer, "query-ok-$cycle").writeText("ok\n")
    check(awaitSmokeEvent<CR.RemoteHostStopped>(desktop, 120).remoteHostId_ == hostId)
    File(peer, "cycle-done-$cycle").writeText("ok\n")
  }
  println("XAUXAT_EXTERNAL_PEER_PAIR_VERIFY_QUERY_DISCONNECT_RECONNECT_OK")
}

private fun configureSmokePaths(ctrl: ChatCtrl, dir: File) {
  val paths = listOf("files", "tmp", "assets", "remote_hosts").map { File(dir, it).absolutePath }
  check(smokeCommand(ctrl, CC.ApiSetAppFilePaths(paths[0], paths[1], paths[2], paths[3])) is CR.CmdOk)
}

private fun smokeCommand(ctrl: ChatCtrl, command: CC): CR {
  val response = json.decodeFromString<API>(chatSendCmdRetry(ctrl, command.cmdString, 0))
  return response.result ?: error("Native smoke command ${command.cmdType} failed: ${response.details}")
}

private inline fun <reified T : CR> awaitSmokeEvent(ctrl: ChatCtrl, seconds: Long = 30): T {
  val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(seconds)
  val seen = mutableListOf<String>()
  while (System.nanoTime() < deadline) {
    val raw = chatRecvMsgWait(ctrl, 1_000_000)
    if (raw.isNotEmpty()) {
      val response = json.decodeFromString<API>(raw)
      val event = response.result
      if (event is T) return event
      check(response !is API.Error) { "Native smoke event failed: ${response.details}" }
      check(event !is CR.RemoteCtrlStopped && event !is CR.RemoteHostStopped) {
        "Remote session stopped before ${T::class.simpleName}: ${response.details}"
      }
      // The core can emit unrelated newer events (e.g. connectionsDiff), which
      // the UI deliberately preserves as CR.Response rather than typed events.
      val expectedType = T::class.simpleName.orEmpty().replaceFirstChar { it.lowercase() }
      check(event !is CR.Invalid && !(event is CR.Response && event.type == expectedType)) {
        "Cannot decode expected native smoke event: ${response.details}"
      }
      if (seen.size < 20) seen.add(response.responseType)
    }
  }
  error("Timed out waiting for ${T::class.simpleName}; received ${seen.joinToString()}")
}
