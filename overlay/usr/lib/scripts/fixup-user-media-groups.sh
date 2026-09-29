#!/bin/bash
# gnome-initial-setup's created user only gets accountsservice's "admin"
# group set (adm, cdrom, dip, lpadmin, plugdev, sudo, ...), not video/audio.
# Local GNOME sessions don't need this -- udev's 70-uaccess.rules already
# grants /dev/video*, /dev/snd/* etc. to whoever's logged into the active
# seat -- but that mechanism doesn't cover SSH/remote sessions, which fall
# back to plain group membership. Idempotent; safe to run every boot.
set -e

for user in $(awk -F: '$3 >= 1000 && $3 < 60000 {print $1}' /etc/passwd); do
    usermod -aG video,audio,render "${user}" 2>/dev/null || true
done
