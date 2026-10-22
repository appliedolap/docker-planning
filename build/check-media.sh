#!/usr/bin/env bash
#
# Checks the Oracle media against the manifests: every file they list is present, and
# its SHA-256 matches. Run it on the host before building (a full check of the 18 GB
# takes seconds), and the build runs it again before it installs or patches anything.
#
#   build/check-media.sh                          check every manifest in ./media
#   build/check-media.sh DIR [MANIFEST ...]       check DIR against the given manifests
#                                                 (names in DIR, or paths)
#
# Works with GNU sha256sum (Linux, recent macOS) or shasum (older macOS), and with the
# bash 3.2 macOS ships.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
media="${1:-$here/../media}"
[ $# -gt 0 ] && shift
media=$(cd "$media" && pwd)

manifests=()
if [ $# -gt 0 ]; then
    for manifest in "$@"; do
        case "$manifest" in
            */*) manifests+=("$manifest") ;;
            *) manifests+=("$media/$manifest") ;;
        esac
    done
else
    for manifest in "$media"/*.sha256; do
        [ -e "$manifest" ] && manifests+=("$manifest")
    done
fi
if [ ${#manifests[@]} -eq 0 ]; then
    echo "No *.sha256 manifests in $media" >&2
    exit 1
fi

if command -v sha256sum > /dev/null; then
    checksum=(sha256sum)
elif command -v shasum > /dev/null; then
    checksum=(shasum -a 256)
else
    echo "Neither sha256sum nor shasum is installed" >&2
    exit 1
fi

# Missing files first: that needs no hashing, and it's the usual mistake.
missing=()
listed=()
for manifest in "${manifests[@]}"; do
    manifest_name=$(basename "$manifest")
    while read -r _ name; do
        [ -n "$name" ] || continue
        listed+=("$name")
        if [ ! -f "$media/$name" ]; then
            missing+=("$name (listed in $manifest_name)")
        fi
    done < "$manifest"
done
if [ ${#listed[@]} -eq 0 ]; then
    echo "The manifests list no files" >&2
    exit 1
fi
if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing from $media:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    echo "Download them from Oracle; see \"Getting the media\" in README.md." >&2
    exit 1
fi

# On the host, also check that .dockerignore lets every listed file into the build. (In
# the build itself, .dockerignore has done its filtering and isn't there.)
if [ -f "$media/.dockerignore" ]; then
    blocked=()
    for name in "${listed[@]}"; do
        grep -q -x -F "!$name" "$media/.dockerignore" || blocked+=("$name")
    done
    if [ ${#blocked[@]} -gt 0 ]; then
        echo "media/.dockerignore would keep these out of the build; add a !<name> line for each:" >&2
        printf '  %s\n' "${blocked[@]}" >&2
        exit 1
    fi
fi

failed=0
for manifest in "${manifests[@]}"; do
    echo "Checking $(basename "$manifest")"
    if ! (cd "$media" && "${checksum[@]}" -c "$manifest"); then
        failed=1
    fi
done
if [ $failed -ne 0 ]; then
    echo "A file above doesn't match Oracle's download (an interrupted copy or sync, usually)." \
         "Download it again." >&2
    exit 1
fi

# Say what else is here, so nobody wonders whether it's needed. "Used" means listed in
# any manifest here, not just the ones checked: the build checks one at a time.
used_names=$(cat "$media"/*.sha256 2> /dev/null | awk 'NF == 2 {print $2}')
others=()
for file in "$media"/*.zip; do
    [ -e "$file" ] || continue
    name=$(basename "$file")
    printf '%s\n' "$used_names" | grep -q -x -F "$name" || others+=("$name")
done
if [ ${#others[@]} -gt 0 ]; then
    echo "Not used by the build (and not sent to Docker): ${others[*]}"
fi
if [ ${#listed[@]} -eq 1 ]; then
    echo "Media OK: 1 file"
else
    echo "Media OK: ${#listed[@]} files"
fi
