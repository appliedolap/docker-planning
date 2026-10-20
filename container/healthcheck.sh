#!/bin/bash
#
# Healthy once configured and both web tiers answer: EPMServer0 (Shared Services) and
# the Essbase managed server. Any HTTP response counts; redirects to a login page are
# what a healthy server sends.

source /home/oracle/container/common.sh

[ -f "$CONFIGURED_MARKER" ] || exit 1

for url in http://localhost:9000/interop/ http://localhost:9010/essbase/; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$url")
    if [ "$code" = "000" ] || [ "$code" -ge 500 ]; then
        echo "$url answered $code"
        exit 1
    fi
done
