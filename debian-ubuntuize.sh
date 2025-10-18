#!/usr/bin/env bash
set -euo pipefail

# Debian → Ubuntu look (GNOME), tuned for Ubuntu 25.10 style.
# - Builds Yaru (light) from source → /usr/local
# - Installs fonts (Ubuntu + Ubuntu Sans/Mono via ZIP + MS Core + Liberation + Noto + DejaVu)
# - Installs & enables: Dash-to-Dock, Desktop Icons NG, AppIndicator
# - Adds Flatpak in GNOME Software + Flathub
# - Sets GRUB "quiet splash"
# - Cleans up build deps; purges curl/unzip at end

REPO_URL_YARU="https://github.com/ubuntu/yaru.git"
YARU_BRANCH="master"  # set to a tag like '24.04' to pin

UBUNTU_SANS_URL="https://github.com/canonical/Ubuntu-Sans-fonts/releases/download/v1.006/UbuntuSans-fonts-1.006.zip"
UBUNTU_SANS_MONO_URL="https://github.com/canonical/Ubuntu-Sans-Mono-fonts/releases/download/v1.006/UbuntuSansMono-fonts-1.006.zip"

# --- feature flags (0 = do step, 1 = skip step) ---
SKIP_FONTS="${SKIP_FONTS:-0}"
SKIP_YARU_BUILD="${SKIP_YARU_BUILD:-0}"
SKIP_FLATPAK="${SKIP_FLATPAK:-0}"
SKIP_PURGE="${SKIP_PURGE:-0}"
ENABLE_MIN_MAX="${ENABLE_MIN_MAX:-1}"
ENABLE_ZRAM="${ENABLE_ZRAM:-1}"           # 1 = configure zram compressed swap
ZRAM_SIZE="${ZRAM_SIZE:-8192}"              # size for /dev/zram0 (e.g., 8192)

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo bash $0 apply | refresh | remove-yaru"
    exit 1
  fi
}

detect_gui_user() {
  GUI_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
  if [[ -z "${GUI_USER}" || "${GUI_USER}" == "root" ]]; then
    echo "Warning: Could not detect a non-root desktop user; settings won't be applied."
    GUI_USER=""
  fi
}

run_as_gui() {
  [[ -z "${GUI_USER}" ]] && return 0
  _uid="$(id -u "${GUI_USER}")"
  sudo -u "${GUI_USER}" env \
    XDG_RUNTIME_DIR="/run/user/${_uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${_uid}/bus" \
    DISPLAY="${DISPLAY:-:0}" \
    "$@"
}

apt_quick_update() { apt-get update -y; }
install_pkgs() { apt_quick_update; apt-get install -y --no-install-recommends "$@"; }

ensure_gnome() {
  if ! command -v gnome-shell >/dev/null 2>&1; then
    echo "Installing GNOME Shell..."
    install_pkgs gnome-shell gdm3 gnome-session
  fi
}

# ---------- Yaru build (source) ----------
install_build_deps() {
  # Yaru toolchain
  install_pkgs git meson ninja-build sassc libglib2.0-dev-bin libxml2-utils \
               bc librsvg2-bin inkscape gdk-pixbuf2.0-dev
}

remove_build_deps() {
  apt-get purge -y git meson ninja-build sassc libglib2.0-dev-bin libxml2-utils \
                   bc librsvg2-bin inkscape gdk-pixbuf2.0-dev || true
  apt-get autoremove -y --purge
}

build_yaru() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cd "${tmpdir}"
  git clone --depth=1 --branch "${YARU_BRANCH}" "${REPO_URL_YARU}" yaru
  cd yaru
  meson setup build
  ninja -C build
  ninja -C build install
  cd /
  rm -rf "${tmpdir}"
  echo "✅ Installed Yaru to /usr/local/share/themes and /usr/local/share/icons"
}

# ---------- Fonts ----------
install_base_fonts() {
  # Tools for ZIP method
  install_pkgs curl unzip
  # Broad coverage fonts (Ubuntu classic + Liberation + Noto + DejaVu + MS core)
  install_pkgs fonts-ubuntu \
               fonts-liberation2 \
               fonts-noto-core fonts-noto-color-emoji \
               fonts-dejavu-core fonts-dejavu-mono \
               ttf-mscorefonts-installer
  # Note: ttf-mscorefonts-installer prompts for EULA; accept to proceed.
}

install_ubuntu_sans_from_releases() {
  local tmpdir
  tmpdir="$(mktemp -d)"

  echo "Downloading Ubuntu Sans (Option A)…"
  curl -fL -o "${tmpdir}/UbuntuSans.zip" "${UBUNTU_SANS_URL}"
  curl -fL -o "${tmpdir}/UbuntuSansMono.zip" "${UBUNTU_SANS_MONO_URL}"

  echo "Installing Ubuntu Sans / Ubuntu Sans Mono to /usr/local/share/fonts …"
  mkdir -p /usr/local/share/fonts/ubuntu-sans /usr/local/share/fonts/ubuntu-sans-mono

  unzip -qo "${tmpdir}/UbuntuSans.zip" -d "${tmpdir}/UbuntuSans"
  find "${tmpdir}/UbuntuSans" -type f -iname '*.ttf' -exec cp -f {} /usr/local/share/fonts/ubuntu-sans/ \;

  unzip -qo "${tmpdir}/UbuntuSansMono.zip" -d "${tmpdir}/UbuntuSansMono"
  find "${tmpdir}/UbuntuSansMono" -type f -iname '*.ttf' -exec cp -f {} /usr/local/share/fonts/ubuntu-sans-mono/ \;

  fc-cache -f
  rm -rf "${tmpdir}"
}

# ---------- GNOME bits ----------
install_gnome_bits() {
  install_pkgs gnome-shell-extensions gnome-tweaks \
               gnome-shell-extension-dashtodock \
               gnome-shell-extension-desktop-icons-ng \
               gnome-shell-extension-appindicator
}

enable_extensions_and_theme() {
  run_as_gui gsettings set org.gnome.shell disable-user-extensions false || true

  run_as_gui gnome-extensions enable dash-to-dock@micxgx.gmail.com || true
  run_as_gui gnome-extensions enable ding@rastersoft.com || true
  run_as_gui gnome-extensions enable user-theme@gnome-shell-extensions.gcampax.github.com || true
  run_as_gui gnome-extensions enable ubuntu-appindicators@ubuntu.com || true

  [[ -z "${GUI_USER}" ]] && return 0
  run_as_gui gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-blue' || true
  run_as_gui gsettings set org.gnome.desktop.interface icon-theme 'Yaru-blue' || true
  run_as_gui gsettings set org.gnome.desktop.interface cursor-theme 'Yaru' || true

  run_as_gui gsettings set org.gnome.shell.extensions.dash-to-dock dock-position 'BOTTOM' || true
  run_as_gui gsettings set org.gnome.shell.extensions.dash-to-dock dash-max-icon-size 42 || true
  run_as_gui gsettings set org.gnome.shell.extensions.dash-to-dock background-color '#0c0c0c' || true
  run_as_gui gsettings set org.gnome.shell.extensions.dash-to-dock transparency-mode 'FIXED' || true
  run_as_gui gsettings set org.gnome.shell.extensions.dash-to-dock custom-background-color true || true
  run_as_gui gsettings set org.gnome.shell.extensions.dash-to-dock background-opacity 0.64000000000000001 || true
  run_as_gui gsettings set org.gnome.shell.extensions.dash-to-dock custom-theme-shrink true || true
  run_as_gui gsettings set org.gnome.shell.extensions.dash-to-dock running-indicator-style 'DOTS' || true
  run_as_gui gsettings set org.gnome.shell.extensions.dash-to-dock icon-size-fixed true || true 
  run_as_gui gsettings set org.gnome.shell.extensions.dash-to-dock autohide true || true
  run_as_gui gsettings set org.gnome.shell.extensions.dash-to-dock click-action 'minimize-or-previews' || true
  run_as_gui gsettings set org.gnome.shell.extensions.user-theme name 'Yaru' || true
}

# ---------- Titlebar buttons (minimize/maximize) toggle ----------
apply_titlebar_buttons() {
  if [[ "${ENABLE_MIN_MAX}" -eq 1 ]]; then
    # Put minimize, maximize, close on the right (Ubuntu-like)
    run_as_gui gsettings set org.gnome.desktop.wm.preferences button-layout ':minimize,maximize,close' || true
  fi
}

# ---------- Apply Ubuntu 25.x font settings (NO FALLBACK) ----------
apply_fonts_like_ubuntu_2510() {
  run_as_gui gsettings set org.gnome.desktop.interface font-name 'Ubuntu Sans 11'
  run_as_gui gsettings set org.gnome.desktop.interface document-font-name 'Sans 11'
  run_as_gui gsettings set org.gnome.desktop.interface monospace-font-name 'Ubuntu Sans Mono 13'
  run_as_gui gsettings set org.gnome.desktop.wm.preferences titlebar-font 'Ubuntu Sans Bold 11'
  run_as_gui gsettings set org.gnome.desktop.interface font-antialiasing 'rgba' || true

}

# ---------- Sound theme ----------


apply_yaru_sound_theme() {
  # Enable event sounds and set the Yaru sound theme (falls back gracefully if unavailable)
  run_as_gui gsettings set org.gnome.desktop.sound event-sounds true || true
  run_as_gui gsettings set org.gnome.desktop.sound theme-name 'Yaru' || true
}

# ---------- Hide "Input Method" (im-config) launcher in GNOME ----------
hide_im_config_in_gnome() {
  local desktop="/usr/share/applications/im-config.desktop"
  if [[ -f "$desktop" ]]; then
    # Remove any existing visibility keys, then set Ubuntu-style restriction
    sed -i '/^OnlyShowIn=/d;/^NotShowIn=/d' "$desktop" || true
    if ! grep -q '^OnlyShowIn=KDE;LXQt;' "$desktop"; then
      printf '\nOnlyShowIn=KDE;LXQt;\n' | tee -a "$desktop" >/dev/null
    fi
    update-desktop-database /usr/share/applications || true
  fi
}

# ---------- Optional purge of stock GNOME apps ----------
purge_unwanted_apps() {
  # Remove Evolution, Calendar, Contacts, LibreOffice suite, Connections, Maps, Videos, Music apps, Parental Controls, Tour, and Sound Recorder
  apt-get purge -y \
    evolution \
    'libreoffice*' \
    gnome-connections gnome-maps totem \
    gnome-music rhythmbox gnome-sound-recorder shotwell \
    malcontent malcontent-gui gnome-tour || true

  # Clean up orphaned dependencies
  apt-get autoremove --purge -y || true
}


# ---------- App Center / Flatpak ----------
configure_flatpak_gnome_software() {
  install_pkgs flatpak flatpak-xdg-utils gnome-software gnome-software-plugin-flatpak
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
}


# Install VLC from Debian packages (deb)
install_deb_vlc() {
  install_pkgs vlc
}

# ---------- ZRAM (compressed swap) ----------
setup_zram() {
  [[ "${ENABLE_ZRAM}" -ne 1 ]] && return 0
  install_pkgs systemd-zram-generator
  # Configure a single zram device with the chosen size and lz4 compression
  tee /etc/systemd/zram-generator.conf >/dev/null <<EOF
[zram0]
zram-size = ${ZRAM_SIZE}
compression-algorithm = lz4
swap-priority = 100
EOF
  systemctl daemon-reload || true
  echo "🔧 zram configured (${ZRAM_SIZE}); will activate on next boot."
}

# ---------- GRUB ----------
set_grub_quiet_splash() {
  if [[ -f /etc/default/grub ]]; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' /etc/default/grub || true
    update-grub || true
  fi
}

# ---------- Yaru remove ----------
remove_yaru() {
  echo "Removing Yaru from /usr/local…"
  rm -rf /usr/local/share/themes/Yaru* /usr/local/share/icons/Yaru* || true
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f /usr/local/share/icons/Yaru 2>/dev/null || true
  fi
  echo "✅ Yaru removed."
}

main() {
  require_root
  local action="${1:-}"
  case "${action}" in
    apply)
      detect_gui_user
      ensure_gnome

      # Build & install Yaru (then clean build deps)
      if [[ "$SKIP_YARU_BUILD" -eq 0 ]]; then
        install_build_deps
        build_yaru
        remove_build_deps
      fi

      # Fonts (base) + Ubuntu Sans from releases
      if [[ "$SKIP_FONTS" -eq 0 ]]; then
        install_base_fonts
        install_ubuntu_sans_from_releases
      fi

      # GNOME: extensions + theme + fonts
      install_gnome_bits
      enable_extensions_and_theme
      apply_titlebar_buttons
      apply_fonts_like_ubuntu_2510
      apply_yaru_sound_theme
      hide_im_config_in_gnome

      # Flatpak + GNOME Software integration + Flathub (no app installs)
      if [[ "$SKIP_FLATPAK" -eq 0 ]]; then
        configure_flatpak_gnome_software
      fi

      install_deb_vlc

      # Purge the ZIP helpers only if we installed fonts in this run
      if [[ "$SKIP_FONTS" -eq 0 ]]; then
        apt-get purge -y curl unzip || true
        apt-get autoremove -y --purge
      fi

      # Optionally purge unwanted stock apps (set SKIP_PURGE=1 to keep them)
      if [[ "$SKIP_PURGE" -eq 0 ]]; then
        purge_unwanted_apps
      fi

      # Configure compressed swap (zram)
      setup_zram

      # GRUB quiet splash
      set_grub_quiet_splash

      echo
      echo "✅ Done. Debian now looks like Ubuntu (Yaru Light, Ubuntu Sans from ZIP, desktop icons, dock, Flatpak in GNOME Software)."
      echo "   Tip: Log out/in to fully refresh GNOME Shell & extensions."
      ;;
    remove-yaru)
      remove_yaru
      ;;
    refresh)
      detect_gui_user
      install_gnome_bits
      enable_extensions_and_theme
      apply_titlebar_buttons
      apply_fonts_like_ubuntu_2510
      apply_yaru_sound_theme
      hide_im_config_in_gnome

      install_deb_vlc

      echo "✅ Settings reapplied."
      ;;
    *)
      echo "Usage: sudo bash $0 apply | refresh | remove-yaru"
      echo "      (set SKIP_FONTS=1 and/or SKIP_YARU_BUILD=1 and/or SKIP_FLATPAK=1 to skip those steps during 'apply')"
      exit 1
      ;;
  esac
}

main "$@"
