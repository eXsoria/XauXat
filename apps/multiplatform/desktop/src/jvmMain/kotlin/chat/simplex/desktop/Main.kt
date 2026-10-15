package chat.simplex.desktop

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationVector1D
import androidx.compose.foundation.*
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.*
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.*
import chat.simplex.common.acquireSingleInstance
import chat.simplex.common.model.ChatController.appPrefs
import chat.simplex.common.model.size
import chat.simplex.common.platform.*
import chat.simplex.common.platform.DesktopPlatform
import chat.simplex.common.showApp
import chat.simplex.common.views.helpers.*
import chat.simplex.common.views.onboarding.OnboardingStage
import kotlinx.coroutines.*
import java.io.File
import java.nio.file.Files
import kotlin.system.exitProcess

fun main(args: Array<String>) {
  if (args.contentEquals(arrayOf("--xauxat-native-smoke-test"))) {
    // Exercise the packaged JNI/core and real SQLCipher migrations without starting networking.
    // The CI launcher also isolates HOME/APPDATA/XDG and JVM user.home from operator data.
    try {
      initHaskell()
      val dir = Files.createTempDirectory("xauxat-native-smoke-").toFile()
      try {
        val migrated = chatMigrateInit(File(dir, "test").absolutePath, "internal-beta-test-key", "yesUp")
        check((migrated[0] as String).contains("\"type\":\"ok\"")) { "Native database migration failed: ${migrated[0]}" }
        val ctrl = migrated[1] as Long
        check(ctrl != 0L)
        try {
          check(chatSendCmdRetry(ctrl, "/users", 0).contains("usersList")) { "Native command failed" }
          verifyInternalBetaRemoteAccess(dir, ctrl)
        } finally {
          chatCloseStore(ctrl)
        }
        println("XAUXAT_NATIVE_SMOKE_OK")
        System.getenv("XAUXAT_DESKTOP_NATIVE_SMOKE_RESULT")?.let { File(it).writeText("native-ok") }
      } finally {
        dir.deleteRecursively()
      }
    } catch (e: Throwable) {
      e.printStackTrace()
      // Avoid the GUI launcher modal blocking a failed CI probe on Windows.
      exitProcess(1)
    }
    exitProcess(0)
  }
  try {
    if (!acquireSingleInstance()) return
    // Clean shared temp dirs only in the owning instance (not in a Files.desktop val
    // initializer, which a transient second instance would also run). Early: before settings writes.
    preferencesTmpDir.deleteRecursively()
    // Disable hardware acceleration
    //System.setProperty("skiko.renderApi", "SOFTWARE")
    initHaskell()
    runMigrations()
    setupUpdateChecker()
    initApp()
    tmpDir.deleteRecursively()
    tmpDir.mkdir()
    // Only the owning instance cleans tmpDir on exit (see preferencesTmpDir above).
    tmpDir.deleteOnExit()
    // showApp is inside the try: its first statements (SystemTray probe, Compose setup) are the
    // process's first AWT init, which is itself a known startup failure cause (#4146). Crashes
    // after the window appears are handled by the WindowExceptionHandler in showApp instead.
    return showApp()
  } catch (e: Throwable) {
    if (System.getenv("XAUXAT_DESKTOP_UI_SMOKE_RESULT") != null) throw e
    showStartupError(e) // the jpackage launcher otherwise hides the error behind "Failed to launch JVM" (#4146)
    throw e
  }
}

@OptIn(ExperimentalComposeUiApi::class)
@Suppress("UnsafeDynamicallyLoadedCode")
private fun initHaskell() {
  val resourcesDir = File(System.getProperty("compose.application.resources.dir"))
  val vlcDir = File(resourcesDir.absolutePath + File.separator + "vlc")
  if (desktopPlatform == DesktopPlatform.WINDOWS_X86_64) {
    windowsLoadRequiredLibs(resourcesDir, vlcDir)
  } else {
    System.load(File(resourcesDir, "libapp-lib.${desktopPlatform.libExtension}").absolutePath)
  }
  // No picture without preloading it, only sound. However, with libs from AppImage it works without preloading
  //val libXcb = "libvlc_xcb_events.so.0.0.0"
  //System.load(File(File(vlcDir, "vlc"), libXcb).absolutePath)
  System.setProperty("jna.library.path", vlcDir.absolutePath)
  //discoverVlcLibs(File(File(vlcDir, "vlc"), "plugins").absolutePath)
  initHS()

  platform = object: PlatformInterface {
    @Composable
    override fun desktopShowAppUpdateNotice() {
      fun showNoticeIfNeeded() {
        if (
          !chatModel.controller.appPrefs.appUpdateNoticeShown.get()
          && chatModel.controller.appPrefs.onboardingStage.get() == OnboardingStage.OnboardingComplete
          && chatModel.chats.size > 3
          && chatModel.activeCallInvitation.value == null
        ) {
          appPrefs.appUpdateNoticeShown.set(true)
          showAppUpdateNotice()
        }
      }
      // Will show notice if chats were loaded before that moment and number of chats > 3
      LaunchedEffect(Unit) {
        showNoticeIfNeeded()
      }
      // Will show notice if chats were loaded later (a lot of chats/slow query) and number of chats > 3
      KeyChangeEffect(chatModel.chats.size) { oldSize ->
        if (oldSize == 0) {
          showNoticeIfNeeded()
        }
      }
    }
  }
}

private fun windowsLoadRequiredLibs(libsTmpDir: File, vlcDir: File) {
  val mainLibs = arrayOf(
    "libcrypto-3-x64.dll",
    "libsimplex.dll",
    "libapp-lib.dll"
  )
  mainLibs.forEach {
    System.load(File(libsTmpDir, it).absolutePath)
  }
  val vlcLibs = arrayOf(
    "libvlccore.dll",
    "libvlc.dll",
    "axvlc.dll",
    "npvlc.dll"
  )
  vlcLibs.forEach {
    System.load(File(vlcDir, it).absolutePath)
  }
}
