#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Huawei BOM-WXX9 M1010 audio repair, version 1.0.0.
# Embedded third-party sources retain their original notices and licenses.
set -Eeuo pipefail
export LC_ALL=C
VERSION=1.0.0
PACKAGE=huawei-bom-wxx9-audio
STATE=/var/lib/huawei-bom-wxx9-audio
SOURCE=/usr/src/huawei-bom-wxx9-audio-1.0.0
CARD=acp3xes83xx
KERNEL=$(uname -r)
SELF=$(readlink -f -- "${BASH_SOURCE[0]}")
UCM=/usr/share/alsa/ucm2
PAYLOAD_SHA256=6aa99b5f22be5176d3639958d628b7edd5cf7f5db4c05944a13460b66c2e1524
COMMAND=${1:-help}

message() { printf '%s\n' "$*"; }
die() { message "ERROR: $*" >&2; exit 1; }
supported_model() {
    [[ $(cat /sys/class/dmi/id/sys_vendor) == HUAWEI &&
       $(cat /sys/class/dmi/id/product_name) == BOM-WXX9 &&
       $(cat /sys/class/dmi/id/product_version) == M1010 ]] ||
        die 'Supported hardware is HUAWEI BOM-WXX9, product version M1010 only.'
}
root_required() {
    if (( EUID != 0 )); then exec sudo -- bash "$SELF" "$@"; fi
}
extract_payload() {
    python3 - "$SELF" "$1" "$PAYLOAD_SHA256" <<'PY'
import base64, hashlib, io, pathlib, sys, tarfile
script, dest, expected = sys.argv[1:]
data = pathlib.Path(script).read_text().split("\n# PAYLOAD_START\n", 1)[1]
raw = base64.b64decode("".join(line[2:] for line in data.splitlines() if line.startswith("# ")), validate=True)
if hashlib.sha256(raw).hexdigest() != expected:
    sys.exit("Embedded payload checksum mismatch.")
with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as archive:
    archive.extractall(dest, filter="data")
PY
}
status() {
    message "Huawei audio fix $VERSION"
    for f in sys_vendor product_name product_version; do
        printf '%s: ' "$f"; cat "/sys/class/dmi/id/$f"
    done
    message "Kernel: $KERNEL"
    cat /proc/asound/cards
    message "Selected module: $(modinfo -n snd_acp_legacy_mach 2>/dev/null || true)"
    message "Running module version: $(cat /sys/module/snd_acp_legacy_mach/version 2>/dev/null || echo 'stock or earlier manual build')"
    message "Running source version: $(cat /sys/module/snd_acp_legacy_mach/srcversion 2>/dev/null || echo 'not loaded')"
    command -v dkms >/dev/null && dkms status -m "$PACKAGE" || true
    if (( EUID != 0 )) && command -v pactl >/dev/null; then
        pactl list short sinks || true
        pactl get-default-sink || true
    fi
    if command -v amixer >/dev/null && [[ -d /dev/snd ]]; then
        for key in 'Left Headphone Mixer Left DAC Switch' 'Right Headphone Mixer Right DAC Switch' 'Headphone Playback Volume' 'Headphone Switch' 'Speaker Switch'; do
            amixer -c "$CARD" cget "name=$key" | awk 'NR==1 || /: values=/' || true
        done
        amixer -c "$CARD" cget "iface=CARD,name=Headphone Jack" | tail -1 || true
    fi
}
repair_mixer() {
    local key
    grep -q "\[$CARD *\]" /proc/asound/cards || die 'Internal ALSA card is missing. Reboot, then run status.'
    for key in 'Left Headphone Mixer Left DAC Switch' 'Right Headphone Mixer Right DAC Switch'; do
        amixer -q -c "$CARD" cset "name=$key" on
    done
    amixer -q -c "$CARD" cset 'name=Headphone Playback Volume' 2,2
    amixer -q -c "$CARD" cset 'name=Headphone Mixer Volume' 9,9
    amixer -q -c "$CARD" cset 'name=DAC Source Mux' 0
}
snapshot() {
    mkdir -p "$STATE"
    chmod 700 "$STATE"
    python3 - "$STATE" "$KERNEL" <<'PY'
import json, os, pathlib, sys, tarfile
state, kernel = pathlib.Path(sys.argv[1]), sys.argv[2]
paths = [
    "usr/share/alsa/ucm2/AMD/acp3x-es83xx/acp3x-es83xx.conf",
    "usr/share/alsa/ucm2/AMD/acp3x-es83xx/HiFi.conf",
    "usr/share/alsa/ucm2/conf.d/acp3x-es83xx/acp3x-es83xx.conf",
    f"lib/modules/{kernel}/updates/huawei-bom-wxx9/snd-acp-legacy-mach.ko",
]
with tarfile.open(state / "before.tar", "w") as archive:
    for name in paths:
        full = pathlib.Path("/") / name
        if full.is_dir():
            sys.exit(f"Expected a file, found directory: {full}")
        if os.path.lexists(full):
            archive.add(full, arcname=name, recursive=False)
(state / "paths.json").write_text(json.dumps(paths))
(state / "kernel").write_text(kernel + "\n")
PY
    if grep -q "\[$CARD *\]" /proc/asound/cards; then
        alsactl -f "$STATE/alsa-before.state" store "$CARD"
    fi
}
restore_files() {
    python3 - "$STATE" <<'PY'
import json, pathlib, sys, tarfile
state = pathlib.Path(sys.argv[1])
paths = json.loads((state / "paths.json").read_text())
for name in paths:
    full = pathlib.Path("/") / name
    if full.is_dir():
        sys.exit(f"Refusing to remove directory: {full}")
    full.unlink(missing_ok=True)
# This root-owned backup may contain original UCM symlinks.
with tarfile.open(state / "before.tar") as archive:
    archive.extractall("/", filter="fully_trusted")
PY
}
registered() { [[ -d /var/lib/dkms/$PACKAGE/$VERSION ]]; }
affected_kernels() {
    { cat "$STATE/kernel" 2>/dev/null || true
      dkms status -m "$PACKAGE" -v "$VERSION" 2>/dev/null |
          awk -F, 'NF>=3 {gsub(/^ +| +$/, "", $2); print $2}'; } | sort -u
}
rollback() {
    local k failed=0
    local kernels=()
    mapfile -t kernels < <(affected_kernels)
    if registered; then dkms remove -m "$PACKAGE" -v "$VERSION" --all || failed=1; fi
    if (( failed )); then
        message "DKMS removal failed. Backup retained in $STATE."
        return 1
    fi
    if [[ -f $STATE/paths.json ]]; then restore_files || return 1; fi
    for k in "${kernels[@]}"; do
        [[ -d /lib/modules/$k ]] || continue
        depmod "$k" || failed=1
        if [[ -f /boot/initrd.img-$k ]]; then update-initramfs -u -k "$k" || failed=1; fi
    done
    if (( failed )); then
        message "Boot image refresh failed. Backup retained. Resolve the error and retry uninstall."
        return 1
    fi
    rm -rf -- "$SOURCE"
    if [[ -f $STATE/alsa-before.state ]] && grep -q "\[$CARD *\]" /proc/asound/cards; then
        alsactl -f "$STATE/alsa-before.state" restore "$CARD" || true
    fi
    rm -rf -- "$STATE"
}
install_profiles() {
    rm -f -- "$UCM/AMD/acp3x-es83xx/acp3x-es83xx.conf" "$UCM/AMD/acp3x-es83xx/HiFi.conf"
    install -D -m644 "$SOURCE/ucm/acp3x-es83xx.conf" "$UCM/AMD/acp3x-es83xx/acp3x-es83xx.conf"
    install -D -m644 "$SOURCE/ucm/HiFi.conf" "$UCM/AMD/acp3x-es83xx/HiFi.conf"
    mkdir -p "$UCM/conf.d/acp3x-es83xx"
    ln -sfn ../../AMD/acp3x-es83xx/acp3x-es83xx.conf "$UCM/conf.d/acp3x-es83xx/acp3x-es83xx.conf"
}
install_fix() {
    supported_model
    [[ $(uname -m) == x86_64 ]] || die 'Only x86_64 is supported.'
    # Keep package VERSION separate from the OS release variables.
    ( . /etc/os-release; [[ $ID == pop && $VERSION_ID == 24.04 ]] ) ||
        die 'This release supports Pop!_OS 24.04 only.'
    if [[ -r /sys/kernel/security/lockdown ]] &&
        ! grep -q '\[none\]' /sys/kernel/security/lockdown; then
        die 'Kernel lockdown is enabled. Signed-module enrollment is outside this installer.'
    fi
    if [[ -f $STATE/complete ]]; then
        dkms install -m "$PACKAGE" -v "$VERSION" -k "$KERNEL"
        install_profiles
        update-initramfs -u -k "$KERNEL"
        message 'Installation refreshed for the current kernel. Save your work and reboot.'
        return
    fi
    [[ ! -e $STATE && ! -e $SOURCE ]] || die 'An incomplete or conflicting installation exists. Run uninstall first.'
    local deps=(build-essential dkms python3 alsa-utils pulseaudio-utils initramfs-tools "linux-headers-$KERNEL")
    local missing=() dep
    for dep in "${deps[@]}"; do
        if [[ $(dpkg-query -W -f='${db:Status-Status}' "$dep" 2>/dev/null || true) != installed ]]; then
            missing+=("$dep")
        fi
    done
    if (( ${#missing[@]} )); then
        apt-get update
        apt-get install -y "${missing[@]}"
    fi
    [[ -f /lib/modules/$KERNEL/build/Makefile ]] || die 'Matching kernel headers are missing.'
    if dkms status | grep -E '(^|[, /])snd-acp-legacy-mach([, /]|$)'; then
        die 'Another DKMS package manages this module. Remove it before installing.'
    fi
    local selected
    selected=$(modinfo -k "$KERNEL" -n snd_acp_legacy_mach)
    case "$selected" in
        /lib/modules/"$KERNEL"/kernel/*|/lib/modules/"$KERNEL"/updates/huawei-bom-wxx9/snd-acp-legacy-mach.ko) ;;
        *) die "A different custom driver is selected: $selected" ;;
    esac
    local legacy="/lib/modules/$KERNEL/updates/huawei-bom-wxx9/snd-acp-legacy-mach.ko"
    if [[ -e $legacy ]]; then
        [[ $(sha256sum "$legacy" | awk '{print $1}') == eaa57abc8f8ed3c356640974ebd5366f4c35d5eb51c779dcbd52e5de6b68efa0 ]] ||
            die 'Unrecognized earlier custom module. Review it before migration.'
    fi
    mkdir -p "$SOURCE"
    local success=0
    # A failed build or install restores the original files and preserves logs.
    trap 'rc=$?; if (( ! success )); then message "Installation failed; rolling back."; rollback || message "Rollback incomplete. Run uninstall before rebooting."; fi; exit "$rc"' EXIT
    extract_payload "$SOURCE"
    dkms add -m "$PACKAGE" -v "$VERSION"
    dkms build -m "$PACKAGE" -v "$VERSION" -k "$KERNEL"
    snapshot
    rm -f -- "$legacy"
    dkms install -m "$PACKAGE" -v "$VERSION" -k "$KERNEL" --force
    [[ $(modinfo -k "$KERNEL" -F version snd_acp_legacy_mach) == "$VERSION" ]] ||
        die 'Module selection failed after DKMS installation.'
    install_profiles
    update-initramfs -u -k "$KERNEL"
    touch "$STATE/complete"
    success=1
    trap - EXIT
    message 'Installed successfully. Save your work and reboot.'
    message 'After reboot, run this script as your normal user with: test'
}
test_audio() {
    supported_model
    (( EUID != 0 )) || die 'Run test as the desktop user, without sudo.'
    command -v pactl >/dev/null || die 'Install pulseaudio-utils first.'
    local sink choice key
    for key in speaker headphones speaker; do
        if [[ $key == speaker ]]; then
            read -r -p 'Unplug headphones, then press Enter to test the built-in speakers. ' choice
        else
            read -r -p 'Insert headphones fully, then press Enter to test them. ' choice
        fi
        sleep 2
        sink=$(pactl list short sinks | awk '/acp3x-es83xx/ {print $2; exit}')
        [[ -n $sink ]] || die 'No internal PipeWire output. Run status.'
        pactl set-default-sink "$sink"
        pactl set-sink-volume "$sink" 25%
        pactl set-sink-mute "$sink" 0
        paplay --device="$sink" --volume=22000 /usr/share/sounds/alsa/Front_Center.wav
        read -r -p 'Did you hear the voice from the expected output? [y/N] ' choice
        [[ $choice == [yY] ]] || die "Playback test failed at: $key. Run status and keep its output."
    done
    message 'Speaker -> headphones -> speaker playback confirmed by the listener.'
    message 'Repeat this test after a reboot and after suspend/resume.'
}
usage() {
    cat <<'HELP'
Huawei BOM-WXX9 M1010 Audio Fix 1.0.0

Usage: bash huawei-audio-fix.sh COMMAND
  install           Install the DKMS driver and persistent ALSA profiles (sudo).
  repair            Restore and save shared mixer controls (sudo).
  status            Print hardware, module, output and mixer diagnostics.
  test              Play quiet audio through speakers/headphones/speakers.
  uninstall         Restore the pre-install files and driver (sudo, then reboot).
  extract DIRECTORY Extract the embedded source, profiles and licenses for review.
  help              Show this help.

Only Pop!_OS 24.04 on HUAWEI BOM-WXX9 M1010 is supported.
Installation requires a reboot. Audio tests require the local desktop session.
HELP
}

case "$COMMAND" in
    install|uninstall|repair)
        root_required "$@"
        exec 9>/run/lock/huawei-bom-wxx9-audio.lock
        flock -n 9 || die 'Another repair operation is running.'
        exec > >(tee -a /var/log/huawei-bom-wxx9-audio.log) 2>&1
        ;;
esac
case "$COMMAND" in
    install) install_fix ;;
    repair)
        supported_model
        repair_mixer
        alsactl store "$CARD"
        message 'Shared playback controls repaired and saved. Run test as the desktop user.'
        ;;
    uninstall)
        if [[ ! -e $STATE && ! -e $SOURCE ]] && ! registered; then
            message 'This package is not installed.'
        else
            rollback
            message 'Pre-install state restored. Save your work and reboot.'
        fi
        ;;
    status) status ;;
    test) test_audio ;;
    extract)
        [[ $# == 2 ]] || die 'Usage: extract DIRECTORY'
        [[ ! -e $2 ]] || die 'Choose a destination that does not already exist.'
        mkdir -p -- "$2"
        extract_payload "$2"
        message "Sources and licenses extracted to $2"
        ;;
    help|--help|-h) usage ;;
    *) usage; exit 2 ;;
esac
exit 0

# PAYLOAD_START
# H4sIAEgH+2oC/+19a3saR5Zwvqqf90dUSCYGBxDobinyLkLYYiIBA8iXtb1sA4XoMdBMdyOJyXh/+3suVd3VzUWyk3hmJ/AkFnTX
# 5dSpU+deVfnt/PZ/Nuz7C2n3pffN7/Ip8GfV30Jhdzf6js+LhZ1i8Rtx/81X+Mz8wPag+2/+mJ+dQzEOnLE8LR4+2zva3X+2t5vf
# P9jdOyha32w+//6fVv26Wa50yvWrq2r7m99v/R8c7OHf4uF+wfzLn/3iN8X9ncODg8IOPS/uAP19Iwpfc/2Pbe+jO1ld7qH3/0c/
# e88O946OCs8Gh7J41LMPdgY7srC/t7+zOyjKnV5Bdg/toyO7v+EG/56f/Eb+b+R/JP8PCrvP8ruHu7vFjfz/Q3ymnpzansxP579f
# H+vlf7FQ3Avl/26xcEjy/3BvI/+/xue7b7dnvrfddSbbcnIrpvNg6E52re9Eq3H+Jnfp9OTEl7lqX04CZ+BI71i8bFzmdvKFnOvl
# RnYgPSuVSp3NnFFfDDx3LIKhFPLe7gWi4U6/7dRb4qP0JnIkfHfm9aTw5K3jO+7kRAxsZyTciegN7cmN7IuRPXdngZ+H9ixnPHW9
# QEztYDhyuvqnJ/U3fzgLnFH4a9adem5P+n74ZB5+nXkjaCLvyb/NpB9YVrNeb4tT3XS+AX/Tnc7AGclOJwPFfHd0K9OZPC6LSWC9
# qF5WWlA+bQn4pK7sjxLLprIiZfemuZG8sXvz3NjuDfM9/ZB+DdWvTs8dj90J/uYm4NnufU76R7v399vmj7CBFa+xhYxl9eUAoe8N
# 04G8DzLH1KozEKlK62j3zZvORaNTKrerryqdy/rrlHAmAstxMfx4tuNL8coezWTF81wvnWrx1NgjD7SAuei5k8B2Jr6whe+MnZHt
# ib/NHO/jCU2evBOzqR9A0bEYOJ4f5FMZDQIwEl/aHoDmpc6q7ffpg/cZGJMB53IA/oLNi64TiAPh+CEgM1/2TzThMHmIiZR9XwGi
# e8a1KT2YpNR3gBxnIoVCxd5R5+rivzpX5cufU1RyBC99KIgQ5f3pyAnoSfqjlFM56funbW8m1XAmfXlPhd85YuB6wslSdUSonMzG
# 0gPqT1P1DI4dv+WRmQT+nQM0xUBlPmjcjOQkrdrMiG9PRXEdQir3U9kLYFG40CGCzzMgaHhOAOtHj50AyMNsSS/Q7b8rfBA/imJ2
# AR8x0hAwQ+mDzPuJaglxgjhM5f/qOhM1MnrjwuKGF1PPuc09lxO7C2tlOO3cTB03DyvduZWdkXsHRQb2yJcnKT1kwnLPnU2CNDTx
# 8KhRCZ0OccgvG9W68GUwm2r2cAKzPJnZI02DuJ4dT/bzceipS5BpI7snsdPsY8D+9ts0F2Ik/7AUXZkT1RNwBW8OtYDYYWlPgRmk
# ozE9Sb//5b3/9H1+jCtU+vD9FH//8u6/f/n04ekTo+T5VbVTeQMddK5K7fLF+zQ+OKuXmuedV5Xaeb0JsF9cl15Xqqn3mewj6zea
# 9fNreFQrXVWg/ln9Kvf6zZtnX9DCq0qzVa3XoJErENGF5S28/5Sl0fYBfdLr9O3A1iNO37pOX7x/+j7zPp1Jv/vvNFDahx8zaWgH
# X3/KcDuM0wEQCdLYyPGDNCE4D3Tbd0C+MJfLmMuISn/GIiJ5NJrTYtIYETQqnkxNQ4ORfYMLntqHRZS/8dzZNL0T42+zLjC39z6y
# avifqhAomv1WaqWzy0oHUFn+xxI2tA7ga81Xx24fJCaDE9K/IvyuBGaEcrSLQteZ3CRWAI8IwRzZ427fFuNjMX5XRI4wfreDf1L/
# WC4psMDuB8WuqUkPVqDH8kPJHVYX0yzTI9kzcVE65wez0YgIH1D0rpB79uFdKfdfdu7v8DX/Y+d/cx+eAspidZcjojq5tUdAPUp1
# 8ORI2r7UAwVKQw0CxhoJ/jwstt7HDkiI6SyI1uO7VH/68SYHot+b44zlXtO/g9Pvf2GxcvyKG/uEz4Hlze5zQzKF/RwihAH4kA0b
# RFSQkOBHGeD4njNNM2Ao6R2cAwVh3iMRk079L7RezLzLFT88gDA7N/jwy2F2r4DwcHNrEVW2J9iSw/rZXNiThPKlhKeCjDQ0hVQ1
# TI3UjxP3DlGaJv1oW6RinsEUakZ2v4PDT8cHrXo4Fb98UkvZExN7THKSlKcIfhg3dWOKyYVBRm2+w2Y+mDDdgox2vRR8xVcxmML6
# EkRQvDXQAHFRp4ZBMPWPt7c9+y5/A33PuqBgeKjtAPaQl29P3WnO9beJDrZ/YdA+bfvIDuDf3rY97qNKtv0Ldv8pFesFJAjIudQL
# CbMJq1LQtOKXmP57DPMK8CDjmPlDQ93QH0RKQmfNw08X1JM0VURrHcj8dG8/I2zUhPypO0kOeQkSdUFCWnqnA6YX/p/J92UP2E06
# NQsGuaNQowLgWcaFCt1/+5N+LqHz5ubAy4//Axl+Ov9j5nsYneo20pSBo0AzVxmT9Ll9oBT6AtyJlbE0cdJ3C5q1u14xdlMf1i2S
# K7c/G9EamLo+KU8mUx3MfJylwEV1ExeQM8GSIxlITdvAlEPmo4e3Tov/wPYFYO1RpRcaTlgVwLNPxZP3kysQzCBZlGBOp4r5Qr6Q
# ypy8nzyJrTzm4Lj+uM08iNGxn87EFiIt0dNTw6KJUxAuC1gGMnzYB0qEcamliNVjr5S9lB9/7DteWt6DIO+4H5lVCn7nJ8idqt15
# AB2v4UjuhAs+BC5jFgxbSLndv+bG4hgkwSJt5l1QbaOiS6kXqy5UE2soTTeZgPPsunp53mGWGYd1kPqFGcCn9xPNUUKVW/GMBktV
# pajEGYbPHAHN6lB1GYZ6MimsSJoWTGmng7PS6dC0djpjsOE6HTWtoBNE86ulOFjJedu7uYX1p1Tb+56cBqJCf3CdAIORuIiiulgH
# ZhcHpsxGbs2m8mjTy/6x+IVqfQLANi62jf//Qf//3qL/f2fj//8q/v+jhP9/Zye/v3d0ePhsf7N0/wAfMiLz/vD37AMX9eHh/sr4
# /25xP/T/Fw7I/1/c3cT//xn+/67tDz/L+e/LQOTkzBVTZypR+lusvYCBXTz+j59j9ju6drXb7pOlQg0iikCJ1PdcOWWNQe8TubJI
# gS3W3R6TAu9vq9fbRLQpcXWa+r7x+jwl1PsNw9rI/438/w3k/z6w62e7m+X0B/j0P479PNj6g99Z/q/L/9uFdwn5v1vYxP+/yqdR
# Kv9celmheNFpajiz76ST67rj3N39/bOcPes7bsrShZTn6VR5niz0erQ7yi2FLbwrfDhd5mhJWeeVVljysl4utaEdKr09m/ZBk/C3
# kRJT1lXpZ24FNRGhtVPxvXKi3ErvU8oqX1ZKAEXgzWTKKl2369Vaq126vDxNzaXPYJ13Km/Kl9ctDG6UmuWL09R/3x8ddA72vk9t
# +NpG/m/k/3L5v/9s71n+8Fnx8PDwaLNO/gAfjqhtaz/7P0P+7+3u7Rn5/wew/uHJzkb+fxX7f7Wtnw6N/cloLupNcdY6z+3myiN7
# 5suM9Z1oD8GgR6pBw37qubdOX/bFbAKCRNiij8k6UGUbmrndESPuIS9eD+VEcMzN9aAVT/YdjCd3ZwHF4XSjWTF3Z2Jsz0XfFb6r
# 2pVOMIQ/ujXrO2ih7E7nnnMzDNK9jNgB2SFK/Vt70gNgrpye54pzeQvl/ayoTnp5URqNBBWn4Kn0bmU/b1nfcZoexn4EZ7NYWpGZ
# 9sa5OQU/VLRoOrKDgeuN825Yxtnx42XggfF62k820TdrK1WJQaCC8biUSiE02us5ifZ6jn497uf8/h0Wc1SAy3hiFKICHAbbUg2Z
# T6Gk9Z0eqfCnsgd00UvixpMT1/HisPAzA1pPjruePekHWC4spJ5F5Q52w4DcwW70+LAQPj4sEFQIHma1rQJKxfYMkOjJAhbjoUCx
# gPaHw4FhU747WNKOfqoK+m6P8YuIpsh3NEE8foX9gPsd6/Gbj6MuYUqXdKmfLowW3xhg/hiVT4CpH8fRY5SPoWdxZH6/Z+coMulz
# vVVvcTIxgvt9ulyvvai+7LRqGEQtd0pX551SudFplK8y1EC0EqHO2irVnVasCq/D9b2cJ3rpP9jLZeVlqfyWkmPqtVjl5Ip9YHzV
# xPicB6pUO1el8kVUKbliF+pSPWygWanVq81Yd+FCXVfr6qxZqp23ExWjxbu6LoB7sGvWo1W9tvxhwSzPy305OhAVWLN1Xi51/nJd
# bf4czfsaelvae6t+XTt/XW1WqNkYcg2+uXJacEaWkYKak5X1FBHFJzTJfVZXb9VfLNY1lvJ6vFHG53KMaUazuufz1ysHrfnPQ5Dr
# NhYqPziCCHMr24hjcKPlb+z/jf3/WPv/IP9sb6d4eLiJ//+B7P+FpMOvZ/8Xd8DsN+z/XVj/+4X9jf3/VT7b21/sANjehv9+EycA
# NPPrvAAMyuf5AVSl0iwYup5/LEp/dQLx8wzmWTRAtZVz8RM+oid5fvKfoB1hnvhzrGttP7XEU3GlbNFzMkHFJS0i0ZpNafMhpuSC
# yiUuXovuyO19hBpQ8ztn0hvN+lL8xKnlPdeT+eHzhedg7nQwtXLsL3urdbZV7/r2dBx/x3nt/bGz7DEnUeCb6JW5mzH+dOUWRcuC
# BRWATQ6zOesFgnZA2l6/0/ducXuQ8IL9g6OdjhcUC8VntGMI9w5YW/mh3+lNZx0H9wGBFddpNbLw1B5Plz2GQfSi57jZJquacPuy
# x0+bbewpbMR8gX1HzURvdENBf9zBTTh6T1vW+nTyyJH5nbF9/xXG1VoysKvSm2cYxC/9bmP7atPW+nrzxrTb8SYPD+sx8PPmqtVQ
# PgIipKCJPTs62tlfB9NFaymq+fFjQK2VrrGPL6Uk4DKdcW/0Efdd0pao34a4vHH3dx31ryGw32rI+ID6MAa6HPYHiajruiNqz0bg
# cHtwx5366VU9P8WtrhkLOqSKQ9vH4uHmXcvacgZC7YeN4U1TdgaB3YrqIR5O4AkJgo5aTCEYP3BL8DUDhT5ZW2pPoap/Yn0KB+JM
# gmgc/szHHdmdKe5T4KGAhd/BVzgc8RT/pWFgNWgUIYc/gtyU2HSsCSp9wmOjUqeimAGgFTQFeIUbx6In1OIK2Dzpz8ayM3X94Eth
# M5v4TWEDFawbYky77zt90nxg7uELAbYSbOQK15eXJ2ERXRX+wrsfsIXcc/jnZKERVEY6qC2Ip/TvKdbt3Migg3Ag8aWj6jjgnjvx
# A71EgM47/twP5Bip7Sn+dPpRJ4t0nHxyEkM3IvNb7s3pd2hTLBMuz0OuUq29KuEwt27cwBXuLCDyBKAYCVBz3Pn4d3sEalsafmSF
# 7/xduoM0T25WvHzR6PxcadYql3ruvqU3sU5q9avK1YpOAA1qKKdi9WrNxMeAlcKt1tDYQoVTEWt7SZHc82iiop6XTGImnKx8REjc
# puqDSIJpgZ+4dxM6iKF9UW2pdJ/wHe84E8nx4GOcsEUOFhtIBstsPxXVgbhz+kBUvgCdnLapee4IfniSdhZiQjLufNOhoR7MYNfu
# fQRWCto6mA1zqD8aia4Udh9Nlan0csTksFoyVtTDWtvJxYv5cs7NzJMdBcrCEv5JFJgQcAVIzzMIHwDZ2tIbd8OWwkGhxUAkmP6T
# nzkWf+q/n6SoSoRE3E8ZZBaoSpUwuJ4COclPwxkxmJBZ1Hi8yLiYv3zpeKn2l46P1hiQa288TXPzXDqlI6yUapbJsCxapHkYGNKr
# eJpOI6N4mqE2YqSdiXjtuiaIRJ7jv9o+82ddxbw8XA7WFvMvXB7whc5J6fBGb2yFwhGdAE+k0FhU5X/4QfC32EJHkcDnKTzNUKyj
# 0z6/wvVVUccNLB+zoZksaTQ+t+z9gRdOB+zBj0DknsQDThIz/TiqpqoC2hLU1q8gag0isWPNozx54wCuPRquCYT4HGi3UmsaBTjD
# zYwRuA/DC3+PrRVyOibuEqIZ577r4uw5ff/dB9YIEfi8YptsdNujHuquqKUSRPkYkQh1LkNnNnInN50g88OisQ21PmXXNO2PSe//
# jNYjg/fBtj8Tbv9RgCvfw6PajZt6y5oE4yOnTC/gJ49rNWmurWpXjSrHo/oSRGjTaAUyIi74mLZjNohuUXxC20Jl6p5XXlXLlU4b
# WUxaU2w2ItTMgqETkTX7w0KhQqnE2tDhd/RjKz8do16pl+F0jGImmxhYRw8KYcyzFDlNKL34BtQK4qrwMgSSjSV2b3US8KXj8OF4
# 1NCrV416s92ptdKpZKw3lTEQ1Co3q4027cdHR19v6LkANY/WZy+gUf4S0FlrVdKpl41LcbuDbzbxv038718p/neY398/2NvbOdzE
# //5Y8T/283/9/N+DnQMz/reH+b8HO7ub+N9Xif89/dL4H9rFHAL7LUKA0MyvCwEKAuW3SAXmljgu+JlhQcTJd85ggkeldSjDj9Kk
# Lix9DmPs4aPjgH+1ex+/LD64KgboTKazYH0UcElzi8HB6HBTKxwjmqbli1KtVrlsbR1Fz3Hk9UaLXMtgqXUzW2n6niHvcB4eRGWx
# aXQcKlOWrVCRXuMm4yKRuwjjs+ISCEq4A/SZ81E5vsgJOilu0dNDRurMt2+ANnEaFSRLzW1RTLxvVq5KDTrzr3PWFjuWhSeEii6Z
# daDkXlRK561Ku3MGeuU56KYF0FVLVw3+Dd+5ovpx1tZfUW+lhjAoAIx66joTIFVosFavVVQ7YewjjFLhl7O2atZshVz5sXbOr6+u
# 3qqGwnBpGAUxg0BR0CQKGvG3Yljy6Ai+6vAXRyjC6SJnCQYMlFc8/ZSU9swaB/qJLhn529CdsKZKViReaXeGeKq/LWtV+d4eBYvh
# R3tUecOZtr58Al8x8gaczSa+czMBPobNhiGxk8SLKCqWfNMNVrwwok4nS7pR4Z+lHa14h12teBULZi28hCkajIOFrtjtFoUCMPz2
# 9A7+TTzqxh7FiI4iTWviFeFXKMV+NnbuAXs6UYEyHfnTv7VzjWdOA+q7g74/XXSjrZt5XXeVC25dXXkfgFUv1kRSEv7Gdx9OjMCR
# OtA4SLh3HxXUArZRXBefQeQpI32BlesITVwmMEfIhPGTZW9Dh+SqWNjCkOLcYw3zIA/f1iNYyO+KhASzW4WNJE9k9mdyuS9AkA5n
# /JPmf5EjPzz6kHd/Nl18doT5tx+wKUxWDTUmcD57kJ8dqv7tB2lKwFWDjEnJFYP8DrDgDDZeiY3/b+P/+x39f0f5o0Lh6Fnx2Wal
# /aH8f6vOJ/69/X+7O7v7+4b/bx/W/8H+5vyff37+v3L//agy5XWmu4reUWr71Tmlt5co3CUnN/iefXroBtg9YJ/DQoI+uuZ2oUHP
# sSeiAUJf3vZs8ROKfznr2f85ngXyPu9O5PNH+8iUe2qJi+y38pyt98Utz8ZnpxpYjcse00UkK55vo0WHl8w81kmn/Ho7vc9y9y0H
# YNU4VuwcQKft5KbTG7roWo2VSOXz2w/vIYi5D1GrDI3vJY6/KMcUC2CeydNMOr1UH83oHB30MhrexfPr0qV2UW7tRM8Xb/DYwjty
# 9jLW6nuFqMR+xvTdLEKok21Bk7c/Sq/jTrQXITzKm5+Fjg+M0atblxaTNfEg+4nEFCZaXou5muxhiSVpIlHBE78nntJXBYqfVb9D
# QGLKv0O35ailItQdOv70Iz3OivilOstqju3pFNmB+ePd7ofFQeF663guLHyBPiIo+m7nw4mZ58w+jphrCI/xn8hRmDBjTmx2sa7R
# JTKA4V2Hnns2tNXBq2dE9BvMYtW4Slqge4zQcGk2S287rep/VdK6RAZTD6j+aQgSPhrb/kd2riIoJg0BbRR3do6OOj8rMuq8aFb+
# gifK74H2VRBPxc7+QSZZxSA7Xd6sUsTrHJJZwRExRqQ2de+ACCXI/gWjkKaBbWrx9E67RPDc96jcR5V0KZ7qb1nqjRoEw20VAJr6
# f+fuV/bPq4LuHplN0wliwAQ+vnznafg1mSmN5TygAtCXxVP1ZZGS46WC/jJad8I1ajuxZbOEuyknZIzwB578WzzfWfdIl+Iw+Lnn
# EYwAhzgNAQiLdAK3A6/S0ZApLVtBZtSAQliWXqXhR1YUsKjyBsR5NrzOPY85BJbermVQc5Sn1+/eqNIhD8uKFKsUttg7uhr+ne5D
# wysUMPkOEaH23CxZIJiSRxfCPLL94k4eFuX6Ppas21imouk39AEv/twH+Z8OkQqYy9L8ZYVOLCpf1ss/d+rX7bUptYRWhrdnT55w
# qjNnLnMfOlMxzEw0HSgMIdND7vnwLq8ZFWbv4bYSg3UiRa7kkWnVCI0DRtB8hce0dC5edxqlZikK/fHihaX7wzKmmlHZp2qDw6dk
# HpnGIqpbeoMWfj9ZV7Azxbv5osL4O55MCQ+2TkV00RznySGfhsc4HX8uwUxguK5xUa9VzDQ7oyoi/srpLa8MWkOzbtReJ4WSLC/G
# AJRnU8OvieW81LjqtBo/p1Mt5qcw4bhjA4VQrMxFI20OdHkhgDYdH9OactUJBhvsUbxgErTrRuPyrXmZXwP5fSoi91q9cUXUUyAa
# Qfb+sKAKi8Y6azQrnQYYIf9IPK632vD8emEYGjiFus8GbYkI+1LAHkUXrBDFQKDUQtKPNGEvzDJeHNioX6aIdle8ba55m5i5T1na
# ekEbKNpD6VGex8QF/kP3vkit1gq+fQ0EFJhxdp/urNFqJu3PGM/uQX4Frt6KIS4aqo6fx5axALatxPoICuuJssHEAoMzuvkGbw8D
# m0Ltz/glsRjiGFj2rrnqXZw01AJeOVNaBelM5F1S2+CdKeH6DWmgWuu0Xlfb5YtoCROhLisQTc/aInr1riwUW7px6luiJ31ePEjt
# 04n4mM8BggVWFm0Fmo07ifKGWr2saiasG+74OV2O71gnRuFVHegiUQ/RylvoJFx8i0MJK6zqKKy7Uvb9xir7Z2jND20JjPWFeiDu
# kbhjVGUeo8AuKImhfrhaK4sWO42eQYWGlJaj9X3SmGJctvKqUmt36rU0F8Ggk9rPaljb0c5VteFnaZFwUywasH1S6G7xajnAwMQf
# STlVcCdsan4YmfsI5mNaCHvXTZjgPJ5uvoql9S9JM1oUGRRz/CsIJprBFeQSK/B/lFgeHQf/FTO2/VS8lnR5N9602Hd82qWBOgBp
# +HhJOcr/uItZQUbqgt7HiRmgwdAOqHy5fl4p62JREbsXzOD7HIHxw9qynxevnWCIt4j3XTT4nCC72Mw2x6JjnfqYeoo723C1cFt4
# h2KIb1ZvpqPZzQ0Z6HmlK4EuA/91ZQ8zZvk99Tsxq+Ld4z4MC4x33DAyciTDzFdUZzkRFhGEUzmWQAgRAkZA5qCQdB3bFyMg3pFS
# rWL4AdoRNy7iHRrSdH9WLbU6rXapdn72lsGtDkToWQwHTNtp+yPZwS6QyqEVXAfY/ETrcY6XQN46xGmVbfUaJqpTDSobfMH1SUsD
# Scesr3U4MkxOHkn+j8+Q+NXkr8i+zzTfl4Hs0a2JuF85QcO8XZn9q0CnAp89EnM8oM9E3A+G2fyZCIzUReRKfvpBNCEyra3Yteza
# pZzveT5vDO/QXfboPT1JlNVXuC8WLZ6sbHfJNfUrml1WUheNebELH8IdapqX57itHCEidbKqmtqQ98NSUFfWwvMHVHbO8gIqw5ly
# a6qdl41qnQ9GBcF2+ZZ+V+srxlKMxhJypscMprhiMFFEYHml9WMpPn4suBacycBdowpg06ACKH4q/gQSN9IsF16qrb7iUeRJJYHe
# kVo6Q+dmmH6I+jKLja+g5wfaXiTXzBes2LHTe+SCJV8zGjuhnVNQDmgnPG5juZ/XCKdl2KPJxXSYJ2oU6WKCEZMUlC0iya0rqu8d
# j9u2WCkq9uOPyvP5qC53Iipf36NpckOVeH/WFobG0w6hSDjiJwNt8PvHHzPKqbuCbv9ESkNIiZpaNESOBiS75AWnfoZkYHS8jh7w
# xI302igGf1mq8ieCkStjBqHXOIPDVZVO1psQob8af/8ak8HIbtRka+Im6bunlEfyIE/kHXmRVX6tnvmUNphiPuNWpa0cfvTorF3r
# FHTBuIBNOql1KcN3kCySWXmuQXgYC8BHmgXljUfXMT8YFsBhUz+oG3yUc7PvPAOcGJT4ufK207gsvW2UrlsVIrk1msY6HUMvOE08
# OqK9VsUgpnQSPxyCYs6IErvfV7u7jdKxJbYockzcKsze2d5kyepUKAU1GPoRpoxhjSsm0ELv56lggw6J06Wrte3RapGl9QhFZQ9q
# NP8hUCCeYwSpc1l/LY6N3xfVlxd6dNVWp9JsLjNCM3GKWqJZurNRP9TkE3BSdzpapqir0W6u7CzGk+Om7GMxldRSlqFqiUb35ZgK
# O/xMVCUBfSSuou4UsmKid500V2uDhmFUeq7Dicv8QOjdkfcBbnGg0xhifBBYOD6OjJmFQCe0gIuOe0rj74Rsyhrclgaug5zfAj/G
# BbelTkHx5NiFqfLdQQDrT3YmgNckijNRuPWhQ1Y0iLgFKIYzPrkO0zpUOsAiUo1cARUDiFxG1ctq7efOeeWFYm0Wu870i3L9qtEh
# Vp6mr2SGp1POTi9XabXeYGLccaEAHDmFKlLxQFw4L5xUJpNZERJa2NATwYmv1L4eI8xJJw1JNcQt3AfYqbwpldt86n8af5/VS83z
# zqtK7bzeRLl2XXpdqVL8YHn5RrN+fg1P8Jo/KP/z5avL3Os3b14/ooq6NhBqXRULxQLX+LTshBJ1xFF6ieZohmK/3vCe/XsO76x+
# 9TVH948lGR9fd8AXr97+G0/nl45u5996dHu/cnSfHhkkfWBX4er9hOFeQvyiBJxvqMD8mMOY6pWZfIjPMmExtOGSQgyfhQVY5P2Q
# FIPhe7X7VpwaGQvVF1dtvFEJEPiP5OPaWaf2Qiw8Lp+BvHvReHT04fM2nBZWnUsa2kCPPFZ0/QF9S+Tro87pi2lYa7P51h9rGh3e
# Gcuo1UO2eZxrsn7VcYCPOmA0cV6o6ZxghZaXeJ9OUeDTte6cYMhxCUZtVgTenA7tcIU+R09QXjxNjLaMtmyerNBUQyXfQD0+Sxtw
# GyeV4omh2r2fK4Y65LfYImM91MgZ6Irn0aGDdCDhwAFInvzJf4K4Ilt4dS/UtqbdXKX2Bh2NW6RxboUY1oOIBjAdzn2nZ49YZbWV
# nroVDnU6C6KnfFpsqNBG8JPRuWoAbCLzbGf5FNO+HGCwE9eQtiki0IErnuERZS8qzXAEykmy+nRbMh+Sp9uq03TxFcMKo1HUmI7p
# 5Sbi9NG3Yb+GDq+5nMpR3zIdh0CssTT4zNKzK2MEbuT54wmzaoklyNif9XrS9wczjAwSylSKUoJOzZTR6Bzf88qrE2thkow1gCda
# C1tliYZzhenbGBEkP3ZWdGccmFMBzr4rfczkHNq30lxP4SLiuuHC0wAuGD8WybPlJ3AvOw/hKZ7HjawV/uaeG+fpJRjziSqxkBK0
# 2giNcn0SNUfsaF0jRXWdhSNslwardemFU2yXxvYQTZvtfpv9v5v9vw/s/32W3y0Un+3tbu7/3uz/xa15v/v5f4Xd3WJy/+/e4cFm
# /+8/+/w/vf83OunvSzbwqhuvjEPxdsHeZrM7cTCe+eKLNJqT8JSQDfP6vyT/dxflf3Ej/7+K/D9cPP+juH90dLgR/38w+R8e5fm7
# rP918v9gL3n+797OQXEj//9F5D8d/xuX/up03b3PPl2XtQFWJkyaEzn8KfgnxczxhBFnJJeoD+rW8YVTdcPHsRNnm7VOo1ztVM+3
# tgr3hWLs3atS7WX95YUuULjfL8TrXp0ZlQ9emC8Pds1Xu+arw4Lx6jDW5GHRfBWD5nDHfLXzlc4729j/G/vfkP/AgXfy+0fFg0Jh
# c/7/H+Ez6423Mfskj57Yb36/9b9G/u/uHob2/27h4BDWP6gBm/u/v8qnxVtQXkmviwGPCuWoteTfZhLEuniHEQ/H78tbG2R5KmUJ
# 9flONKU9nY7mwh/aGKWYjuw57b3CJC86TGOAMcDSZaskMPQrUQUI8OyusI0eZlCncNvB6ZNLOQhEtO/8yrmnu7Th4XmpLFq01/uJ
# cCeppbWbpJQkq/PTx9Q3NrzrYbxyR7OxfCJ2sjvL61C7nBB+Nbt/Igopa+sDhmKqA7qyFbFZdkGCUyIuxpLa86kULTorC35VxtNg
# LlLf/3Jre8esN51DtU8pCu+8wH0neTU5/DafwmxzaqkMahJmXKfOnRsn4MR3z+Vt4hhse4VbBjlQV7anwcyTDc9xPQc6LBYK5uPy
# lUgN746//6Vse/1q/1N2GTxh8bI+EWmHwnrwH4w3AaTe0c7jV3Cqhz5CB0gZjJweEgnXISqLNrr7hMilpGjiX2/TN+eW6p3zJqvH
# VxwMVM0IbZoMEmgLHyfRhkj6jk4wQFdV8UDQjRkcELxo5OzxVNwNnd4QE/v1IQjm8QhU3fX0U0r+pL2BfDqC0TWRdmUkx+YxDfQw
# ZZayMXjIxYBQU8unykB5bLbMqVg5X3qeH0Td7sOo+7WD2/ozPC6rvcpGVXysX1+8vsKjNAy4V6EE0/sX8KF2exir7AH6PHcGA+mh
# MYXrEznEyJkUc7D6i6lEUaP9ODknGgzXOrf3hNiM2lP4JFnc3BTz+YvkcSAt72PJekpyIaaJVUwoFb0zKKJ0XhaNlyXx0nYmZgmD
# GqDIUmrQI1H0QBO/Uf029t/G/ltl/x3tFDf23x/F/ouf9/zb24EP2H9g+u0m7L89+Lux/76K/TefBPa9OLCsc/JE5iPVH4yT73/B
# xMMcZ/odB2DAnE574ywfFXnaYwmcHThy1D91+llP3sj7U9JLnoAUt85cNzBVjO9ES+JeG1SBfbGtzvDC4y6+zBbc+lIjkCEB3YlV
# qrFzT0ePgfqdMpUqKtjGwzR0op4NSh0nFfc4mc+lW+jojBZU7QNW3hEsKGKtV+AKqEYyJBcNcYt3CrmiIPpn1tbnWKcrCvP4dcln
# 2WdRb4gO6C4BHjxc6OCw8CdCwuV5qV0S7Tp+KWdFU/+EL+XFZhJ2MTagFE68Vs+FybyVI6FUtHj10mVZKM0urlFq2BXRLcKP+qGu
# GQP/Q6jlX/uybPuo5uN+K9RMX+Cthant0tV5PAUmdImlDDsAsYMH0QlP9lyvT7u2xN9m9ghV2quZD+b5/znNcqP/bfS/WPx/v5gv
# Hu0VYQo2+t8f4KPuT/W3VbA3H9wHX9f/v7e3A9+j+D/qf7uHh5v7f7/K5xVIr/666L/1YAnOD3iw2I+PacnLjexAehblJFw3L4/F
# MAim/vH2tj/t3+dd72Z7gWKHwXhkXePFrbmXM6cvjy0h2q7AE9doS4WqQKdssWKCmzOyAo+qRUXJHZDTdeCORu4dhi6wc2gjsG+2
# SbETU9vx8Ag2PPSBchQk7WJDJUBtesIGpiO7J/EV1L1BQPAyNl8fbcdQYHFvNpJ4LlpvhoXpoA4MirxwPfHkZe1avJQT6YGe2Jh1
# oZJQ+KLbmDPiVno+BhR2yMX8BEd5TPGJh7I4oBBes/yIkirf4/MBwlN654ImUD/+DAB//BwINZ3oQm15Hxxbahs+wVypVZqlS9G4
# PruslgX8X6m1KpY+GFW80mBnxZ9nQATFZ8+KlmWmuJQz8PDoWZZeiReeBIVUHUsAqJlN+jRznOqStcRPmlAH/oDo9LklKoCFOZIY
# 3ostvbETBOz670E3pEmGN15LxFgXmsRreqd4BCDTpUG/mmLY8MCD1PkwwYCPYwaKRALGA/b0idQNNNNA67ZwRYQ0CMSHBxSNcb+M
# PmiBzi/sS7XrCgna/ggP70DhncOasQYw/L47xjcU8CPgCQQ8nS4vxNmcT222fXWm4iLh6MkSdJxhICd97upmZns2/JbUlVjXFb6z
# NMy5HBQZI5w+6vy8lUsNB68OxxnDgWLo0gl8pETPzws6ltFaQdM2n7+InRN+FG+Izb4Vzf4T38DghE+FgSXARuHUc288eyzuhi62
# TPeJ+8Q+YMoC1+JLBwh76Rae/sjVVlFabHA995Y2h3Xnlkb2pdP1bG++arWqQ7nzGSHeujM6E5IDuAwMoV5B7MMMum4eqYYuab9T
# cSrEBmFVQ5LFVwiRh9sQPcUL1QRmkSatqYdxFSHq0PxyyPwF2jPnFGxvAM1SG+SkSR3G2uElswCfSCva8W6IFCzeYic9CmM5A7pY
# /s7xh5ls2BUadxKPgjNkheCNmHSeixNYuqKNh58FRlUsoyg1Ro10sTgICAeaJiixkYnAI8MJXo33EyYi3dzHiXsXttsnIcMybXLj
# 0+yAlIOqeIokLx1OtqNZ0SetEi4x9O45ZAKrs0MBGV2nbwGxIntCZMoJLXXViUrb45Ak3mJDr1ycFQ8XrkcD5FJ5q811Yr14eGAt
# xv2R3UkvsB3crehP4aXTdcBkdhQfwpYZo9bSGTUxmUWIFPrHbt8ZIPkSKlBYyXt7PB1BIVViaXP+rDcEKa5QDrgaSlx2FvwKHBox
# 8QwxkNAQ9QMaorhxFP0BdTjQFJ6QinwlwgLhFZcRbebM8yqjuglyhipzWmDZkNQM8oK3lkF50E4JSCKEwx8CSUCZsSYGkCo+H4kr
# 50wwdB6rpacG17BcRiVqD/cdzGkgQXCJdDFDconFXxzrQJZWeieDnhjpKTIxJBPHthFHPr3Ei6xHLPF8krJK5GXNGVYn+qtpNPsj
# qEsjHzCEcyHxhm5mn8Bv1VCwVVwsMCAmeFqNmuAVwVmEcKml8AwJF9T9ST86QTe8zAA6Rik0py5pdDFhAxNRHSzIGALeIT5MB/hi
# L7R3GEGb2r4Pr1BHuJOW4ha+SUEArpoyAOZOEwfvBlYyHXt0YUqciT3KQh88JBQyuD93JMckSz23P+sxGCREfN4djg0Aax7h1LuT
# WFuWkkdPoAAowiRhmFxe4OvRPEudmOwJQQqGdCU5Mmo6ZQEGBSKERq+E4xRf430OSHfIW4mD0GYe2viM3NHjEYMA0+SAkhEWp81I
# DyUnDsKZ9J1bp88HOrtdYiTcSajP4KnkQrJrFuaf5NAwagb+ghiSYOfN84pp8lHyOM1EPITxsd2no3Z7I2krCAEFakC8/LqhDtVn
# 0lSk9USpG8jl4THiPSxnk2KW1zrYFOc/XLkkn3SWEPNDXCgwgmzEvhStW0xtPXW0H5kreev/Paz0wtt2pXnVEqXauSjXa+fVdrVe
# a4kX9Sb8bLyt1l5mxXm11W5Wz67xFRW8qp9XX1TLJXyAwBfyfKD1ElVJkSMhG0bAesyd631UnAE1Q5g237IRNSh7yVYiekWiiNjO
# 0B2hcPHtuVJtx6CBdqXByvvWLJQ/jEOtJy9XL/KM9lSD4UuB9iwBcVmLdJYQfBILxhgQeuJ7QJMpGkrX5tVMPevWLD6PWzo0ZOON
# toYAVDz4A7k8tcLARwMe2XfHvKYdggVGDt1yWYU2Rc6xlsXU9YgMSJnIWgqA0IbAESB/N0nG1yw3lM19ZdNOaMasEazNGZjRqJBe
# AGcERoBJfNmwAp1VjQyH7nDsUxd4mvrIAZVWvZ5YemZEyuw9hZpnBVm5WhnE4ux+H5QCWia+SIHsSMFCKeF5fawguAqvqFitWhex
# QZIyiYpnpCEzdShyOGEWS1rZLPAdWvIgQaF1TSo2csuB5c0mC6hXTFlrOrKfVRqb1HffDDx3bFaxDGWdksKcAXVIJ+5N+IsfOAFJ
# RLFAaJbuOY1nAuPJB8iLYNKBYyFwXQn6OTEuGOcSiDN56zUrOCIkMjy9ndvysRctd8JBYqyL2FUxz0qMPX+Mwap1NdXME9/UY3B6
# TeUa1WZnQitkDFJgRgcGusDmZaT/WoiaqdObuTN/xL0DzyFeDrSLZ3jgQgcBA4MgHUEBaZayopWmOI8aRG9kO2O8smgQSv4TOokf
# lwRSgNLuLK7ma4mF+g/5e0xOOAnz+eyuT8FOlGUwtrBpC8uQEhnZh4YiEEcdOZlgKJqxqX4smy4FVWfvhKVhqsJZYkuHlFelxwCr
# VQfTKLrmxazNNe6JFby5asVWeiKfvql0vlA9MvQvFLr32jLXSjNRzk5EOUq/oxZ5VN5ygtEcU3E2izkblJiRXBwzuCtZcVbJUqZT
# U9Ek1h5nhIrBiyWiRIUKRdGyu+6tXEKXQBqgcI+lZCLhUfjSkOPHFrmx7ExkBPANEHTHhdYZcXsT8fwe4JYQC2PE5a1IzuLbWOyA
# 17S2MQnfzHO4Bc2B+mhtKcLjUnmGo7sAB9EmIiBs1sAXIEetLGXaAk/HZu5AONNbUsC8IBTr9MxnUYfjSrBANbHUBtUjtdsdoBEU
# 06goXZZ7sRELmp5RRNFqdLx+2AoS0CpNQIt+Hn4vo1X3EPVa0E+Arkiv9DBoT74Zsg7QPeXxsbGjuRo8MFpgsIZNyKhEGqWXdFYo
# tK25MK4IJD2qbjRISqK+74R8TOhFRs/NnU2GIZ5fhEzew0mZcsyZ6WkycWcT9jErIUyLIsbxxFKOZ1MD6sFq2yeNOi3YL1mtgYX0
# oVYBwxFWyEQOC/Ku0Yo31HqmeI1tmi5qIblglBiVo5GWX9icIGPXFbcO3q0W44nUSqThpSv3PUns6hgFbExkB74cDbTPUc8BwEZN
# oKwjkR5SAiOfvQSTGMqzzMRiHEiPZlFDwLOs2AXDLSYay2dAc9d+Eyo7ZqcC+eSUNAnplfqMlgcZo5ajHOOUV+FL5XghBKE5SVVY
# GVq5NLMkl9D30EU4bN/FpGZy5aJqxMdPRXoHFg4v/cMOfKXvjQHHt2iH4a0wsTXIM4saDy3RrL4PxhinC6ItBJ+WUoIhkb/D9hNd
# o9N5FoQVrATR+XidRdgs1CbWQzYms5gwId8UKlZSqBBjNRVOJbS4DW0UqlqaC1lxDLADOHKHsJ3HSoBWhsGGuEeXuJp6C6fWU91o
# JXNG0oLdIfCAjE8elidvbK8PwoDmHyqJOxTT7BxrQ8WsESZASMn/HoQMU+GJhBEqRob/jxRVP7BM1xEUY+vOw4gGaAEELDsCoNyJ
# gFkakuEQdUXmjSXvpcfmr3acsW+Ik7WXIdswoFwP1LkRejO0OeUvVQVgzNUJmhYOR2jGyOnsmxvEkm5W2Tw8DsTKsoaspK5FDJIe
# rtFEMvjbxgQlvAkJqMEWuPMJDCvF06Pxse4bcaGup/mfAR2zTaJptFKWSrnd9ap6cghJ6NGEZGGq1Z+dDMoot/tX9KloHzjMXm/G
# J0CiRrZE/upMK18UCYYdQVrUKiUKmMGyCGykP5V6eJ0AqitAv+Fs4LORJFnnsU+ZBKG6PSyHwhyBZAXKDPnymter1nAqrNEEWdbE
# h0MTrCavB625Y9tzgP5n2jEUOQlR6LA2dgIozIYa2eLI7HA9kcqdxaxCh5sDnI2AOwfkf+NxzaXtUaAmMitIQSKGMM8qhVxpUBMM
# Z7EDesIBPVKMVIRLWwgo/aSndW2FOJNesxz+JtxTC0mMGzI6OTmxeSDFjwXw4+ZgNf55JF8wB71V1IVHRoIyQMvAsFlJP1WCmSaI
# ZX8iDrViyKijkPfMHtGWGeJgSo1RYVt2DwzIfTihJAPglGC2Lbg7tBsBhR7WD+Ezda2HFy+NN1RQ7ZDq0Cyn1AYu0Zp1tXToMvZB
# dUHNJRYgG0RMRd9QR65OtDN5Osah5MRCGIxTntq4ZYaX1GFE9AUZDSbQ7JELlz73blHv3KWOxyzABc+hE8q6cCKrJYv38flkmdi+
# 7/Yc7RCDJWAj4WM+NO/eJDtLlWc+7DlTjijTdcZafiFwjvKTkdqDHvLRyDYVh2hEMMoLmPhbRDrqdpY/lTTjUiuz2YXxmMuFQnwo
# NZQ/DqN5FBwMXT2hUmtWS6PZzu5C1TLgqEsWiIXzlIlWwtj+K2kA4aWAaR4hQvwRyFiOWDXxkY1n1AgtkFEeG63qMFNyMiHjjY8f
# LSXA6mxCegvBHHZlKbXdViuUHM1x7OFO2wVtwWgdVSxjBWC0RvnJiNBxF65NB8KGCRmkHdsqFE3UQG5qpdXqWgLVdWDNCGWigQXq
# 0+o2KaPUGLyYkZ7vW8vUyhiXxCAF6sezm6HB2x0VMWcn53gqRyMjqcRoJOEuMpCBUQMh9iKdAamIHUHsrgH7j5zorL+aWktMl7CY
# UpF65f0UHbl8si6Les3ODVUFo5noYAKqmAYW6Th3pA26K7tf3TvyT4wrMQ1SrMieoRgIlDBDKeLgRMbinkvAssJ1qBGMKjQFhULm
# yj4rQoYOs9P0ooTQGprhEwzjbzpzwfGi9JsQMFo6NE1o3iAv1gCAPYiBLvgPzytmtufgUTuk7u3z1GnzzrQ2kSSnQcIG8x10Surg
# NJGOSrcgZhsOH5ViInGMYd6gic9u23goV7n0gIWvmBj0BwV+MvbBuTdo8draKvMoSDd0uk7ArvqRfRdG75WhuDgebgeEi4ux6e6c
# A2Pkr4gp2AnnfVo5GFc62TPs3MGAYy+kGu7fVk7d2BwHpMBimBo9jjrN6HMCewxxCL6VQGLCxFGpDgd5jqPQ1WysoKxT9R8YcSyp
# IbGAFPGjiaxXo2Zplg4kqzecKcKLOO5LNAL8Gi5Y3cSLAgxnyxXBUJ1CodiTA5JBeS4HM4/iVbGEE2WDRU71JyI0NhVzVQyA6BpQ
# MaQQV96KrySVocJaEli28G8P5ylagSqkZLBjGkfCIjvMi+qABTu5U/Q2KPJAgBAAq/2vs/4N+fJYSTGsU445W6CJosSRutBAzaeO
# H6C/RqQ52jx2VG6hilfDcp1JP5O1DCokZZjwSISAtJNW+S84KIYKND/SSMBc1h1HnDqj5TSm+sEyCZSmH3aRWCNZDrfxWkZxgc5P
# 7DcUjavrcsqFyn/C6qZP31XauI9ZO0BevjOejWCZSg4WcQADZMiN0isjrm+ZYRsjW0/CXJL73aimRP/CJKLqrQlzxdpTYf/FzCRb
# z26YPRPeF8Y5osJz52AmzHOUUmAsbkNP0L0A82O116U0HDcMsKkQSx/EQg9TNMhtH/4CM5K0ChgHD5E4DxkWKuVT8C1mGr1dQBIq
# z+yIMuUcFesiM8SIuodCK3QH0SSvAZ91OCPos+CQgq9DOUJNmo1hzKSb8KKUpOWx6KUmcDH2ZiMbOK3j9WZjn7g2c7iuPYpYuDSb
# NzJRLXZK6niKLmSEJRKZqyqBcsIkZJndYgS1GnO5TWcecbAlPjeYmZmSz/SLV72RfeJHaRXo6AdSnSvvGbnrdKKe8tWx4wA3pXE0
# yCJvNpc8iXeOR5SwyjiKQaijfCqTBgd946kWdRpmZGDHpljfCKL9q5aDpI+chEX8lNMzNPVPySWPCBPiiuZRulA+SsmxbjCvA5Y1
# cx3VTWiK32EI36MYJGb3LYAk+5amdmJdyiahbETFz90JO7x9YpyU19IzbDYblCWqdKKcqLNpGO6lJKrtvjvhCeiD9OlLvhoe58Qf
# Es2gMkjiPeYsCGHV8EXMSAHJ6SdhvoRig0oSMiMeug7phO3EqjHJlFLiEFDsBb37lOB0p4zELqBB3vIC6MpFacVS1Q8W/Y5oRBzl
# dXAt6afYVlmvCY7l+Eb6BIYPdHIoGUYeMi1lnSKtRNTfnUeRLdNOZx4dqSMLuUTIFcn08mNwLJoBxNHxUk/yOyAROHiFIxafDimC
# HhuikfQCco1jcRYz4nAoWU7NtIN41dh2AHbnTEgJGIMpYEWIYNYx81UHso8iccLBqZ7N0tXgxaDku7CCMUTiW7znJAQR1jlQpXYw
# qvBj1+3Pl7qTn+UpE2ZlKjpiSmdfePLWoegtTzkmNavNH76l5n5FSjrrAKjF4nKCvzC8Fo7NbIMWDxImSHgHmTtu45k6HqWtazeT
# jwtX1eDtEQhhn47gwQp9CSQ2IhbPCUfURZhByWEOIERKgSTlWm9rAcSgfxX9jTiFMMczGDTyRV1iMht3pRflh2rbmLw5A7LWE2UX
# DAlmlUZCnZK0KWTesf00qWxkxZHI1jkaxvalyIEaV6h1kpiOEGqgXE9nDcS60hMcpekhOVhLyGFh7FFAg5EwX4aCRJBsHuawuFrP
# 11XQNl0OzbI9GZy6VMhr5VHnoBqrg3SFhfwTyoVj/mtmofoqfhdbwQmluq8Pe8rSEpNx+WCpHHpU3yNLWqmGoRQI45Emm3sA84nu
# Vq3XE9rC4Y4lLjLfInkQOhn9MONZbdNAIUZ4Jx8GrDzazBbCginjN649otU95YN9NdmxWgAsZ8bpvHRDlXYC0CO9wye2b4Zbcsdu
# aLPjzh/ObcDd9kqMhFVumJ+M5tFWp1pdvMbL8WrttzT/xbw4q5TxcmrRvqiIRrP+slm6EtWWzoo9Fy+alYqovxDli1LzZSWL5ZoV
# LGG2hTmyRgNZPPQAf1fetCu1tmhUmlfVdhtaO3srSo0GNI4XCYrL0mvAZuVNudJoi9cXlZpVx+ZfVwGeVruEFao18bpZbVdrL6lB
# TMRtVl9etMVF/fK80qRs3W3onSqKRqnZrlZaFsDxqnoeH1Sq1AKwU+J1tX1Rv26HwOPgSrW34udq7TwrKlVqqPKm0ay0YPwWtF29
# Aogr8LJaK19en1Mi8Bm0UKu3AU8wMoCzXSfU6LK6dQAG2reuKk3AX61dOqteVqFLzBx+UW3XoAvKLy4x5OXryxIM4rrZqLcq6L9B
# FEIjgPBmtfWzKLUshdi/XJfChgC70MZVqVamiUpMJA5XvK1fo9SAcV+eYwFLF0BEVQReflZuV1/B9EJJ6KZ1fVVR+G61CUGXl6JW
# KQO8peZb0ao0X1XLiAerWWmUqoB+zJFuNrGVeo15y04eJw+opPIKaeC6domjbVb+cg3jWUIJ2EbpJVAbItOYd+t1FTrHGUpOfpaq
# wIto8t8CGdXFVektJ2a/VeQBYIaZ23GqAKKIqLN0VkccnAE8VQILAEGE4BSdl65KLyutrBUSAXWtksmzotWolKv4Bd4D6cFcXzJW
# YBX95RpnER6oRkQJphOHhnSopgzXINJaTdMI9J1cl+mo7wT9IV1c1ltIbIJOHSGI4e9ZBUs3KzXAFy2nUrl83YSlhSWwBkDTuobF
# Vq3RpFg4XlrN1ea5Xk+EZ/GiVL28bi7QGPRcBxRik0Rr4YRoImtlskQDovoCuipfqNkTsVX7VlzAVJxVoFjp/FUVOQ/3Y8FaaFUV
# TuqqBYXHvN7LCquEyy9J4MfcfyxywWlSJbJG2cPaJvkPD98iw62BsqOknI8UrCRjH49hcacgnJU2FOVRGvvbVJaeEpY3tP/DDyyw
# QdhNNvND+cOmnbK40WRAZwL5pIdoYrDSw3nuJIOcwIrLApaB4YYdTEyKOTeNraBhsFi7D/WOOO2SDQJbhZwi1ShM5nXNYCnqL2QK
# +fYAh4YQh7XH4VGdgUogogQcFWPByGC4WZR3oHDOICgIt3KuYlagvPtKTYuSjSmFB5uiNvwhOVJIsdPRftLhU6E6kMITJJXbSkxd
# soAoFYcy+WigMw460O5GlOuAJJUE+RPik+rrjAEDAU9AWcMIFTfdBdtjIEDk25xMZBMVUFb4c2orvkn6J8xEeA49UBMo9Unpec79
# kl1qbCCKzfdJuLsxNsus/UabwziDMlie7rlsp3GUme3H9MYwW2+1ohRtpNC72rmTyygYRq2k41nSmUX9Ob8cAWYoVplhQ8zqCRSe
# tdIFywqmM8vpImDQaOGOTEgL+JNwB4YKFZJ7d0QZgzqlExRtbCIppwG5jxDTLUl0YoUbjFYYcjRVtIsX7SxfDR0d6yZdR4kUsTyR
# dfOHsTHOvw1vnFW4PEF7FmgdTGwAMtx9f3d3l7+ZzOInRTzHTSWYb4TWvZnegR4wZp6UFcA7JFHRlZhl5rkTgIW38oHeDjzLGbHL
# MpZpEcsszWrOpjeE2IgCL0zGHTkfmQ9alLjoBMxXfN4NEctRBeKXKhPq5QSU41vWyjVpHjzLJlYiLkQRX4ULtXtgBai9n6WzVv0S
# tIbLt6bGe0KzqSZS4JFv4n9o1+ndk3xE0MmVHEkNYuNyhP3wbcCxhU0tqD1Qod9Hm1InZne9JyYgeU45Gc6naKBRfCrK1tbwEQxh
# bUV5esdsbFdIzP5buW+sPqCQiIpiRP1RyNdH7+QcHRMYK6NILthX5BkwNi0tBU3tQWIPO63crrTGLjSZ6wEEH8khMZaTGSBMjv1c
# DnkwGcH+zOGIbLhXX+3+UIOlpDrcRkxFJPACdw7V0nrHephGrGqPpZcRvAfbs3w0vUcco5hwJjoGiXEDXORUi7bOpKIdJlpzcAbW
# BLe4+7zT8kJlmNuY/zAdAbun7Ceqg2TK+yTeunO3P59IdZIGheW687AjzuuJAKAVgrqFYp6qc2jofww6f4KBLcr1g9Xo81ZcX6gM
# E0xg8TOhMww6+zNCIy7s3kfpEfP6iVNAcNM2UEl7DivNnTzPiiJoWZ4zopNBUN3gF1k8acN39N6sV0BByiO7gq+F/hEV8Yl8E0g/
# 5vySV8IydrCGhwWE4THPZEU2Blf5DH5kNnQkROhcsXReN+2sRIbNUobChgwJXsOLMJg9Gh5xP8wnsVTj2vnDTOFOp3fq7dh9UMX0
# zpclp1RYy0+pWHRKbk7q+nc+/29z/98/7fy/w2XnPx8c7G/u//tjnf8HqoOdm/XGOTz1NBfK29/s/L+9lec/7xV39hPnPwP9HW7O
# //sanxdkC0XH7KH91Jddx56QCdV3e9tTUItsPGosB+rvDOhkO6SOHJtS28V8Ydu6nvK50LkaaFPHIkZQ0csyG1rHoHN5vjuyb8XP
# c1+O8PJg0Ovu/9MHbSHf+/tziw8RPhaDYIqnqgXTPLUIignmjhF0YNuDkde11Am9x8rYJnjxRBhMQcShUHwS1TzcaimuMCW7N4wu
# IlLeH0y4RIskCnVwSokzpTxItQtWaB8CQQPKCp0vQulsmF2ATw0EgjKJRwz7x+KpFRprx2KnUHyWoyuUwwsUL53J7B5PTgZDoeT1
# hg7mX6D+mcY7lDK6E529dCzOWue5XTAYcBdq2Av3vJ3obKfAnZ3TW76U6UqP1vNXtbn88cI1kGoo2c8fy7IbImFa4L+mXNj2MIsd
# 4YhPOGmdNhfgMS6omKrtWS5u7zQ3FmTJLo2C7vH9SHEnYSK2B1bdMcFUzCfA4vOkjHxv2ljkSTJr+TQA93ZxQ2422sE6cjivwuxS
# ZR9F8EQmF+NmZxEO6M9AhoZjyscCrQNFecToLKfPAkWbX7FjLNVOEnLdsRE8Ro+YA4siwniYkG4OgUe2mxc14ygV7cpYekTMxDUM
# ST4GxVe7mibRmULq+Bi1UUPQZbecU87xRrIfAUlBfPt6hJbINa08bSqs38NtvUhtyog04ro0lPZFtSVa9Rft1yUOKqrAHYWHVsb7
# 0LnPsZw6PFBxPYveoN9Pxe5EFLkzonGPCeJZy6N44kuieAIGZuGxQeXLUvWqch4PirUuMLC2bKAqdhQNMwxKWdwXDPS8igE3HFH0
# TceejIBU5U0FhlNqvs0uBKSsMCKVfgAtMDHl62blCqGmKMxZq11tYzTtZb1+jsi2VFiw0joJQ1HXrUqW4lDUNbQB6ILX8P3sulUl
# xFVr7Uqzed3AWE0GBv8aMANtUVD6nFBMJy0ROdSbFAJCPNAMZDFoTCEkQCphq4RYwEBfuW0UsyiiVW+2zQharfLysvqyQlFTFYnC
# wHNGB+ewTXYjQ6exOJ3F3w3SjQJc8eCVWB282hjrm8/ms/lsPpvP5rP5bD6bz+az+Ww+/4Kf/w+kqBy2AEABAA==
