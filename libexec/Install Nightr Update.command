#!/bin/sh
set -eu
PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
export PATH
exec /Applications/Nightr.app/Contents/MacOS/nightr-native package desktop-update
