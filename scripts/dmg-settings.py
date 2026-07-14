# Settings for dmgbuild — headless pretty DMG creation (mirrors the
# create-dmg arguments used in build-dist-macos.sh).
# Usage:
#   dmgbuild -s dmg-settings.py -D app=<bundle.app> [-D background=<png>]
#            [-D volicon=<icns>] "<volume name>" <output.dmg>
import os.path

app = defines.get('app', 'cr2xt.app')
appname = os.path.basename(app)

format = 'UDZO'
files = [app]
symlinks = {'Applications': '/Applications'}

_volicon = defines.get('volicon', None)
if _volicon and os.path.exists(_volicon):
    icon = _volicon

_background = defines.get('background', None)
if _background and os.path.exists(_background):
    background = _background

window_rect = ((200, 120), (540, 380))
icon_size = 100
icon_locations = {
    appname: (135, 120),
    'Applications': (405, 120),
}
hide_extension = [appname]
