#!/bin/bash
#
# Installs the recorder desktop: TigerVNC for the X server, noVNC to put it in a browser
# tab on port 6080, Openbox so the installer's and configurator's dialogs can be focused
# and moved, and an xterm. Recorder images only; never the runtime image. Runs as root.

set -euo pipefail

dnf -y install oracle-epel-release-el8
dnf -y install tigervnc-server novnc python3-websockify xterm openbox dejavu-sans-mono-fonts xdotool
dnf clean all
rm -rf /var/cache/dnf
