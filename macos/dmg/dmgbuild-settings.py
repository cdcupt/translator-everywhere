# dmgbuild settings for the Translator Everywhere installer DMG.
#
# dmgbuild writes the .DS_Store window layout DIRECTLY (via ds_store/mac_alias),
# so the styled drag-to-install window is produced headlessly and DETERMINISTICALLY.
#
# CLEAN, SOLID-COLOR BACKGROUND (deliberate):
#   On macOS 26 (Darwin 25) Finder will NOT render a DMG *picture* background —
#   neither the AppleScript `set background picture` path (fails -10006) nor a
#   .DS_Store backgroundImageAlias (the alias never resolves; the window shows
#   white). Finder DOES honor a solid background COLOR. A clean warm canvas with
#   the app + Applications side by side is also the look we want, so we use a
#   solid color and skip the picture entirely. Verified rendering on macOS 26.
#
# Invoked by build-dmg.sh:
#   dmgbuild -s dmgbuild-settings.py -D app="<abs path to .app>" \
#     "Translator Everywhere" "<out.dmg>"
import os.path

app = defines.get("app", "Translator Everywhere.app")
# normpath strips any trailing slash so basename never yields "" (a trailing
# slash, e.g. "Some.app/", would otherwise mis-target icon_locations).
appname = os.path.basename(os.path.normpath(app))

# ---- volume contents -------------------------------------------------------
format = "UDZO"            # compressed, read-only (final distributable)
files = [app]
symlinks = {"Applications": "/Applications"}

# ---- window + icon layout --------------------------------------------------
# Soft warm off-white (#f1ece3): clean and intentional, harmonizes with the
# cream/pine app icon. Overridable via -D background="#rrggbb".
background = defines.get("background", "#f1ece3")
window_rect = ((220, 220), (660, 420))   # ((x, y), (w, h))
default_view = "icon-view"
icon_size = 120
text_size = 13

# Icon centers, window-relative, top-left origin (app left, Applications right).
icon_locations = {
    appname:        (180, 215),
    "Applications": (480, 215),
}

# Clean chrome: no toolbar / sidebar / status bar.
arrange_by = None
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
