"""Packaging and storage isolation guards for the XauXat Desktop fork."""
from pathlib import Path
import re,struct
r=Path(__file__).resolve().parents[2]
p=r/'apps/multiplatform'
s=(p/'desktop/build.gradle.kts').read_text()
assert 'bundleID = "pt.exsoria.xauxat.desktop"' in s
assert 'packageName = "SimpleX"' not in s
assert 'CC9EFBC8-AFFF-40D8-BB69-FCD7CE99EFB9' not in s
assert 'licenseFile.set(rootProject.file("../../LICENSE"))' in s
platform=(p/'common/src/desktopMain/kotlin/chat/simplex/common/platform/Platform.desktop.kt').read_text()
assert '"/simplex"' not in platform and 'File.separator + "SimpleX"' not in platform
assert 'xauxat-desktop-' in platform
brand=(p/'common/src/commonMain/kotlin/chat/simplex/common/platform/XauXatDesktopBrand.kt').read_text()
assert 'automaticUpdatesEnabled = false' in brand
assert 'https://smp5.simplex.im/a#' in brand
updater=(p/'common/src/desktopMain/kotlin/chat/simplex/common/views/helpers/AppUpdater.kt').read_text()
assert updater.count('if (!XauXatDesktopBrand.automaticUpdatesEnabled)')==2
assert 'repos/simplex-chat/simplex-chat/releases' not in updater
assert 'repos/eXsoria/XauXat/releases' in updater
icons=p/'desktop/src/jvmMain/resources/distribute'
assert (icons/'xauxat.png').read_bytes()==(r/'apps/ios/Shared/Assets.xcassets/LightAppIcon.appiconset/1024.png').read_bytes()
ico=(icons/'xauxat.ico').read_bytes();assert struct.unpack('<HHH',ico[:6])==(0,1,1)
assert ico[22:]==(r/'apps/ios/Shared/Assets.xcassets/LightAppIcon.appiconset/180.png').read_bytes()
icns=(icons/'xauxat.icns').read_bytes();assert icns[:4]==b'icns' and struct.unpack('>I',icns[4:8])[0]==len(icns)
print('XauXat Desktop identity, private storage isolation, update separation and icon containers verified.')
