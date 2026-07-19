#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Desktop-only package list. Edit this array to extend the installed session
# without touching partitioning or bootloader code.
NIRI_PACKAGES=(
    niri
    greetd
    greetd-tuigreet
    alacritty
    waybar
    fuzzel
    mako
    swaybg
    swayidle
    swaylock
    xwayland-satellite
    xdg-desktop-portal-gtk
    xdg-desktop-portal-gnome
    udiskie
    lxqt-policykit
    wl-clipboard
    grim
    slurp
    brightnessctl
    playerctl
    xdg-user-dirs
    otf-font-awesome
)

usage() {
    printf 'Использование: niri.sh USERNAME\n'
}

main() {
    require_root
    (($# == 1)) || { usage >&2; exit 2; }

    local target_user=$1
    local user_home
    id "${target_user}" >/dev/null 2>&1 || die "Пользователь ${target_user} не найден."
    user_home="$(getent passwd "${target_user}" | cut -d: -f6)"
    [[ -n "${user_home}" && -d "${user_home}" ]] || die "Домашний каталог ${target_user} не найден."
    [[ -f "${SCRIPT_DIR}/assets/bg.jpg" ]] || die "Не найден assets/bg.jpg."

    log_info "Установка полного окружения niri..."
    pacman -S --needed --noconfirm "${NIRI_PACKAGES[@]}"

    install -d -m 0755 /usr/share/backgrounds/archplus
    install -m 0644 "${SCRIPT_DIR}/assets/bg.jpg" /usr/share/backgrounds/archplus/bg.jpg

    install -d -o "${target_user}" -g users -m 0755 \
        "${user_home}/.config/niri" "${user_home}/.config/waybar" \
        "${user_home}/Pictures/Screenshots"

    cat >"${user_home}/.config/niri/config.kdl" <<'NIRI_CONFIG'
input {
    keyboard {
        xkb {
            layout "us,ru"
            options "grp:alt_shift_toggle"
        }
    }

    touchpad {
        tap
        natural-scroll
    }
}

layout {
    gaps 12
    center-focused-column "never"
    default-column-width { proportion 0.5; }
}

prefer-no-csd
screenshot-path "~/Pictures/Screenshots/Screenshot from %Y-%m-%d %H-%M-%S.png"

spawn-at-startup "mako"
spawn-at-startup "waybar"
spawn-at-startup "swaybg" "-i" "/usr/share/backgrounds/archplus/bg.jpg" "-m" "fill"
spawn-at-startup "udiskie" "--tray"
spawn-at-startup "lxqt-policykit-agent"
spawn-at-startup "swayidle" "-w" "timeout" "600" "swaylock -f" "timeout" "660" "niri msg action power-off-monitors" "before-sleep" "swaylock -f"

hotkey-overlay { skip-at-startup; }

binds {
    Mod+Shift+Slash { show-hotkey-overlay; }
    Mod+T { spawn "alacritty"; }
    Mod+D { spawn "fuzzel"; }
    Super+Alt+L { spawn "swaylock"; }

    Mod+Q { close-window; }
    Mod+Left  { focus-column-left; }
    Mod+Right { focus-column-right; }
    Mod+Up    { focus-window-or-workspace-up; }
    Mod+Down  { focus-window-or-workspace-down; }
    Mod+Shift+Left  { move-column-left; }
    Mod+Shift+Right { move-column-right; }
    Mod+Shift+Up    { move-window-up; }
    Mod+Shift+Down  { move-window-down; }

    Mod+Page_Down { focus-workspace-down; }
    Mod+Page_Up   { focus-workspace-up; }
    Mod+Shift+Page_Down { move-column-to-workspace-down; }
    Mod+Shift+Page_Up   { move-column-to-workspace-up; }

    Mod+Comma  { consume-or-expel-window-left; }
    Mod+Period { consume-or-expel-window-right; }
    Mod+R { switch-preset-column-width; }
    Mod+F { maximize-column; }
    Mod+Shift+F { fullscreen-window; }
    Mod+C { center-column; }

    Print      { screenshot; }
    Ctrl+Print { screenshot-screen; }
    Alt+Print  { screenshot-window; }

    XF86AudioRaiseVolume allow-when-locked=true { spawn-sh "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.1+ -l 1.0"; }
    XF86AudioLowerVolume allow-when-locked=true { spawn-sh "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.1-"; }
    XF86AudioMute allow-when-locked=true { spawn-sh "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"; }
    XF86AudioMicMute allow-when-locked=true { spawn-sh "wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"; }
    XF86AudioPlay allow-when-locked=true { spawn "playerctl" "play-pause"; }
    XF86AudioPrev allow-when-locked=true { spawn "playerctl" "previous"; }
    XF86AudioNext allow-when-locked=true { spawn "playerctl" "next"; }
    XF86MonBrightnessUp allow-when-locked=true { spawn "brightnessctl" "set" "+10%"; }
    XF86MonBrightnessDown allow-when-locked=true { spawn "brightnessctl" "set" "10%-"; }

    Mod+Shift+E { quit; }
}
NIRI_CONFIG

    cat >"${user_home}/.config/waybar/config.jsonc" <<'WAYBAR_CONFIG'
{
    "layer": "top",
    "position": "top",
    "spacing": 8,
    "modules-left": ["niri/workspaces", "niri/window"],
    "modules-right": ["pulseaudio", "network", "cpu", "memory", "clock", "tray"],
    "clock": { "format": "{:%a %d %b  %H:%M}" },
    "network": {
        "format-wifi": "  {essid} {signalStrength}%",
        "format-ethernet": "LAN {ipaddr}",
        "format-disconnected": "offline"
    },
    "pulseaudio": {
        "format": "{icon} {volume}%",
        "format-muted": "muted",
        "format-icons": ["", "", ""],
        "on-click": "pavucontrol"
    }
}
WAYBAR_CONFIG

    cat >"${user_home}/.config/waybar/style.css" <<'WAYBAR_STYLE'
* {
    font-family: "Noto Sans", "Font Awesome 7 Free", "Font Awesome 6 Free", "Font Awesome 5 Free";
    font-size: 13px;
}

window#waybar {
    background: rgba(24, 24, 27, 0.92);
    color: #f4f4f5;
}

#workspaces button, #window, #pulseaudio, #network, #cpu, #memory, #clock, #tray {
    padding: 0 9px;
}

#workspaces button.active, #workspaces button.focused {
    background: #7c3aed;
    color: #ffffff;
}
WAYBAR_STYLE

    chown -R "${target_user}:users" "${user_home}/.config" "${user_home}/Pictures"

    install -d -m 0755 /etc/greetd
    cat >/etc/greetd/config.toml <<'GREETD_CONFIG'
[terminal]
vt = 2

[default_session]
command = "tuigreet --time --remember --remember-session --sessions /usr/share/wayland-sessions --cmd niri-session"
user = "greeter"
GREETD_CONFIG

    runuser -u "${target_user}" -- env HOME="${user_home}" xdg-user-dirs-update
    runuser -u "${target_user}" -- env HOME="${user_home}" \
        XDG_CONFIG_HOME="${user_home}/.config" niri validate
    log_success "Окружение niri настроено для ${target_user}."
}

main "$@"
