#!/bin/bash
#
# A throwaway X desktop for running Oracle's GUI installer and configurator, served to a
# browser by noVNC at http://localhost:6080/vnc.html. No VNC password: compose publishes
# 6080 on 127.0.0.1 only, and these containers exist only for recording response files.

set -euo pipefail

export DISPLAY=:1
geometry=${VNC_GEOMETRY:-1600x1000}

Xvnc :1 -geometry "$geometry" -depth 24 -SecurityTypes None -localhost -AlwaysShared &
for _ in $(seq 1 30); do
    xdpyinfo > /dev/null 2>&1 && break
    sleep 1
done

openbox &

# A terminal to run installTool.sh / configtool.sh from. Relaunched if closed.
(
    while true; do
        xterm -geometry 140x40+20+20 -fa 'DejaVu Sans Mono' -fs 10 -title "EPM recorder" || true
        sleep 1
    done
) &

echo "noVNC: http://localhost:6080/vnc.html?autoconnect=true&resize=remote"
exec websockify --web /usr/share/novnc 6080 localhost:5901
