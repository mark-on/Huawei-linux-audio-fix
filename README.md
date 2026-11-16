# Huawei BOM-WXX9 Audio Fix

A single-file installer for speaker and wired-headphone playback on **HUAWEI BOM-WXX9, product version M1010**, with AMD ACP and the Everest codec exposed as `acp3x-es83xx`.

Version **1.0.0** targets **Pop!_OS 24.04, x86_64**. Speaker playback, fully inserted headphones, and automatic switching were confirmed by the owner of one BOM-WXX9 M1010 using kernel **7.0.11-76070011-generic** during development. The consolidated installer has been build-tested and has not yet completed a full install/reboot/suspend test on that machine.

Other Huawei models, Windows, other Linux distributions, microphone capture, and Bluetooth audio have not been validated. The installer rejects other models and distributions. Board-specific GPIO polarity must be verified before expanding the model list.

## What it fixes

Three separate issues were observed on the reference laptop.

1. The installed ALSA UCM package lacked the `acp3x-es83xx` profile.
2. ALSA restored disabled left/right DAC mixer routes after reboot. An initial one-time mixer adjustment could therefore stop working after a restart.
3. The machine driver configured headphone amplifier enable as active-high. The working configuration for this laptop uses active-low. With the original setting, audio could be audible during partial jack insertion and disappear when the plug was fully inserted.

The installer supplies the upstream UCM profile with shared playback routing reapplied in its `EnableSequence`, patches only the exact BOM-WXX9 M1010 DMI entry, and registers the module with DKMS. The `repair` command can immediately restore and save the shared mixer controls. Speaker/headphone switches remain under the kernel and audio session's control.

## Install

Save `huawei-audio-fix.sh` locally. Review it and this document, then run from its directory.

```bash
bash huawei-audio-fix.sh install
```

The script requests sudo and installs missing build/runtime dependencies through APT, including headers for the running kernel. It builds the module before replacing the audio profiles, creates a root-owned backup, installs the DKMS module, and refreshes the initramfs. Save your work and reboot when installation succeeds.

It loads the replacement at boot. Reloading this driver while the system is running caused occupied GPIO resources and a temporarily missing sound card during development.

The installer can migrate the exact earlier manually compiled module used during this repair. It checks that module's SHA-256 and rejects unknown custom replacements. Uninstall restores the state from immediately before this installer ran, which may include the earlier manual fix.

## Verify after reboot

Run as your normal desktop user.

```bash
bash huawei-audio-fix.sh status
bash huawei-audio-fix.sh test
```

`test` guides you through speakers, fully inserted headphones, and speakers again. It selects the internal output and sets its volume to 25% before playing a short voice sample. Confirm the actual output by listening. Repeat after another reboot and after suspend/resume before reporting the fix as persistent.

`Headphones` means listening only. `Headset` additionally enables a microphone. Microphone operation is outside the validated scope of this release.

If the card is present but playback is silent, lower the desktop volume first and run:

```bash
bash huawei-audio-fix.sh repair
bash huawei-audio-fix.sh test
```

`repair` enables both shared DAC routes, sets the headphone playback control to `2,2`, sets the headphone mixer to `9,9`, selects normal stereo DAC routing, and saves **only the internal card** with `alsactl`. These were the successful values on the reference laptop. Per-output desktop volume remains adjustable.

## Kernel updates

DKMS attempts to rebuild automatically when new kernel headers are installed. For the reference source revision, all required source files are embedded. For another Pop!_OS kernel, the build helper obtains the exact source commit recorded in that kernel's header package from `pop-os/linux` over HTTPS.

The helper checks the module's object list, the model's existing DMI flags, the GPIO assignment, and the availability of the quirk bit before patching. Compilation also checks the target kernel's exported symbols.

**Future kernel compatibility is not guaranteed.** A changed driver layout, an upstream implementation of this fix, missing headers, a source download failure, or an incompatible API stops the build instead of installing that build. Check DKMS output after kernel upgrades. A DKMS error can cause the kernel package installation to report a failure that needs attention. Keep a previously working kernel available until the new one passes playback tests.

```bash
dkms status -m huawei-bom-wxx9-audio
```

Rerunning `install` refreshes the UCM files and attempts installation for the currently running kernel. This is also useful if a distribution update replaced the profiles.

## Diagnostics and recovery

```bash
bash huawei-audio-fix.sh status > audio-status.txt 2>&1
```

Administrative operations append output to `/var/log/huawei-bom-wxx9-audio.log`. Diagnostics can contain device names and kernel information. Review them before sharing.

Backups are stored in `/var/lib/huawei-bom-wxx9-audio`, accessible to root. A failed initial installation attempts rollback. If rollback reports an error, retain the backup, resolve that error, and rerun `uninstall` before rebooting.

To undo a successful installation:

```bash
bash huawei-audio-fix.sh uninstall
```

Save your work and reboot. This removes this DKMS package, restores the previous UCM files and earlier manual module when present, restores the saved internal-card mixer state when available, and refreshes the affected boot images. It does not uninstall APT dependencies. Restoring the backup replaces subsequent edits to those same UCM files.

Kernel lockdown must be disabled for this release. Systems requiring trusted module signing need a separately reviewed signing and key-enrollment workflow. The installer refuses installation under kernel lockdown.

## Inspect the embedded source

No prebuilt kernel binary is distributed. The shell script contains a checksummed source archive, profiles, build helper, and third-party license notices.

```bash
bash huawei-audio-fix.sh extract review-source
```

The embedded checksum detects accidental payload damage. It is not an authenticity signature.

The source for the tested kernel is pinned to Pop!_OS commit `49748809f7e18ca62f2e054523f1e2c0eb7a88ad`. The helper applies a guarded patch during each build. You can inspect `prepare.py`, `vendor/`, `ucm/`, `dkms.conf`, and `licenses/` in the extracted directory.

## Validation for this release

- Shell syntax and command dispatch checked.
- Embedded archive checksum and extraction verified.
- Patched module compiled directly and through an isolated DKMS tree against the reference kernel headers.
- Exported symbol versions compared with the original module.
- Both UCM files parsed by the installed ALSA configuration parser.
- Backup/restore tested on a staged filesystem, including absent files and symlinks.
- Patch targeting and changed-layout rejection checked.

Full privileged installation, rollback, unattended kernel upgrades, and suspend/resume of this consolidated package still require hardware validation. The earlier individual changes, including the driver quirk and mixer repair, produced working speaker/headphone playback on the reference laptop.

## Attribution and licenses

The installer and build helpers are provided under **GPL-2.0-or-later**, without warranty. Bundled Linux files retain their own SPDX notices, including GPL-2.0-only and GPL-2.0-or-later terms. The bundled UCM files derive from ALSA's BSD-3-Clause-licensed configuration. Full notices and the GPL text are included in the extractable archive.

The headphone polarity workaround was independently documented by Xellanox for BOM-WXX9. This package automates deployment of that model-specific idea and the ALSA configuration repairs found during this investigation.

- [Pop!_OS kernel sources at the embedded revision](https://github.com/pop-os/linux/tree/49748809f7e18ca62f2e054523f1e2c0eb7a88ad/sound/soc/amd/acp)
- [Upstream ALSA UCM profile, v1.2.11](https://github.com/alsa-project/alsa-ucm-conf/tree/v1.2.11/ucm2/AMD/acp3x-es83xx)
- [Xellanox's BOM-WXX9 headphone polarity fix](https://github.com/Xellanox/Huawei-Matebook-14-Audio)
- [Ubuntu DKMS documentation](https://manpages.ubuntu.com/manpages/noble/man8/dkms.8.html)
