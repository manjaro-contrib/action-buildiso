#!/usr/bin/env bash
# Give the buildiso chroots a resolver.
#
# buildiso reaches its chroots through mkchroot -> basestrap, which copies
# the host keyring and mirrorlist but not /etc/resolv.conf, and mounts the
# API filesystems with the chroot_api_mount variant that carries no
# resolv.conf bind - unlike chroot-run, used for package builds, which does.
#
# So every chroot resolves nothing: pacman-mirrors cannot rank mirrors and
# falls back to a random mirrorlist, and post-install scriptlets that fetch
# anything fail. Both are silent - the build still succeeds.
#
# chroot_create is the single door every overlay goes through (rootfs,
# desktopfs, livefs, mhwdfs), so writing the resolver there covers all of
# them without naming each stage. Idempotent: safe to run more than once.
set -euo pipefail

LIB=${MANJARO_TOOLS_LIB:-/usr/lib/manjaro-tools}
IMAGE_SH="$LIB/util-iso-image.sh"
ISO_SH="$LIB/util-iso.sh"
RESOLV_SH="$LIB/util-resolv.sh"

for f in "$IMAGE_SH" "$ISO_SH"; do
  [ -f "$f" ] || { echo "not found: $f" >&2; exit 1; }
done

cat > "$RESOLV_SH" <<'EOF'
# shellcheck shell=bash
write_resolv_conf() {
    # a chroot inherits no resolver; without one pacman-mirrors reports
    # "Internet connection appears to be down" and randomises the mirrorlist
    install -Dm644 /dev/null "$1/etc/resolv.conf"
    local ns
    for ns in ${CHROOT_NAMESERVERS:-1.1.1.1 8.8.8.8}; do
        printf 'nameserver %s\n' "$ns" >> "$1/etc/resolv.conf"
    done
}
EOF

if ! grep -q util-resolv "$ISO_SH"; then
  sed -i "1a source $RESOLV_SH" "$ISO_SH"
fi

if ! grep -q write_resolv_conf "$IMAGE_SH"; then
  python3 - "$IMAGE_SH" <<'EOF'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = """    setarch "${target_arch}" \\
        mkchroot ${mkchroot_args[*]} ${flag} $@
}"""
new = """    setarch "${target_arch}" \\
        mkchroot ${mkchroot_args[*]} ${flag} $@ || return 1
    write_resolv_conf "$1"
}"""
if old not in text:
    raise SystemExit("chroot_create is not in the expected shape")
path.write_text(text.replace(old, new, 1))
EOF
fi

grep -q write_resolv_conf "$IMAGE_SH" || { echo "patch did not apply" >&2; exit 1; }
grep -q util-resolv "$ISO_SH" || { echo "source line missing" >&2; exit 1; }
echo "chroot dns enabled"
