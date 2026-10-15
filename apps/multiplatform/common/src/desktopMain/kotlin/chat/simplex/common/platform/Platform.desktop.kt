package chat.simplex.common.platform

import java.io.File
import java.util.*

private val home = System.getProperty("user.home")
private val unixConfigPath = (System.getenv("XDG_CONFIG_HOME") ?: "$home/.config") + "/xauxat"
private val unixDataPath = (System.getenv("XDG_DATA_HOME") ?: "$home/.local/share") + "/xauxat"
val desktopPlatform = detectDesktopPlatform()

enum class DesktopPlatform(val libExtension: String, val configPath: String, val dataPath: String, val githubAssetName: String) {
  LINUX_X86_64("so", unixConfigPath, unixDataPath, "xauxat-desktop-x86_64.AppImage"),
  LINUX_AARCH64("so", unixConfigPath, unixDataPath, "xauxat-desktop-aarch64.AppImage"),
  WINDOWS_X86_64("dll", System.getenv("AppData") + File.separator + XauXatDesktopBrand.name, System.getenv("AppData") + File.separator + XauXatDesktopBrand.name, "xauxat-desktop-windows-x86_64.msi"),
  MAC_X86_64("dylib", unixConfigPath, unixDataPath, "xauxat-desktop-macos-x86_64.dmg"),
  MAC_AARCH64("dylib", unixConfigPath, unixDataPath, "xauxat-desktop-macos-aarch64.dmg");

  fun isLinux() = this == LINUX_X86_64 || this == LINUX_AARCH64
  fun isWindows() = this == WINDOWS_X86_64
  fun isMac() = this == MAC_X86_64 || this == MAC_AARCH64
}

private fun detectDesktopPlatform(): DesktopPlatform {
  val os = System.getProperty("os.name", "generic").lowercase(Locale.ENGLISH)
  val arch = System.getProperty("os.arch")
  return when {
    os == "linux" && (arch.contains("x86") || arch == "amd64") -> DesktopPlatform.LINUX_X86_64
    os == "linux" && arch == "aarch64" -> DesktopPlatform.LINUX_AARCH64
    os.contains("windows") && (arch.contains("x86") || arch == "amd64") -> DesktopPlatform.WINDOWS_X86_64
    os.contains("mac") && arch.contains("x86") -> DesktopPlatform.MAC_X86_64
    os.contains("mac") && arch.contains("aarch64") -> DesktopPlatform.MAC_AARCH64
    else -> TODO("Currently, your processor's architecture ($arch) or os ($os) are unsupported. Please, contact us")
  }
}
