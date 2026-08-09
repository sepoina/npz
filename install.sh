#!/bin/sh
#
# install.sh — installs npz on any Linux distribution.
#
# This file is in English, unlike the rest of the repository: it is the one
# people read before piping it into a shell, and they are not the people who
# work on npz.
#
# It picks the format on its own: the native package wherever a package manager
# can install it, the tarball everywhere else. The reason to prefer the native
# package is not elegance — it is that `pacman -R npz` exists while
# `rm /usr/local/bin/npz` has to be remembered. An installer that leaves no way
# out has the very flaw `npz detach` exists to avoid.
#
# ── why /bin/sh and not bash ─────────────────────────────────────────────────
#
# Because it is the only thing you can assume on a distribution you have never
# seen: Alpine has `ash`, a minimal Debian container has no bash at all. The
# rest of the repository is bash and stays bash; this file is the exception.
#
# Usage:
#   curl -fsSL https://github.com/sepoina/npz/releases/latest/download/install.sh | sh
#   sh install.sh                  after reading it, which is the better habit
#
#   NPZ_VERSION=0.2.5 sh install.sh   a specific version instead of the latest
#   NPZ_METHOD=tarball sh install.sh  just the binary, into /usr/local/bin
#
set -eu

# Where the project lives. This is a copy of `URL` in `progetto.conf`, and it
# cannot be avoided: this script is downloaded on its own, without the
# repository around it. `npz_go/build/bin/coerenza.sh` checks it on every
# release — the marker below is what ties the two together. A copy is not
# forbidden here, it is made unable to diverge in silence.
PROJECT="https://github.com/sepoina/npz" # coerenza: URL

# The four programs npz needs at run time. This script does not install them:
# they belong to the distribution, and the native packages already declare them.
# They are listed here to say what is missing while it still helps.
NEEDED="mkfs.erofs erofsfuse fuse-overlayfs fusermount3"

red()   { printf '\033[31m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }
info()  { printf '  %s\n' "$*"; }
die()   { printf '\n  [%s] %s\n\n' "$(red error)" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# ── where we are ─────────────────────────────────────────────────────────────

[ "$(uname -s)" = Linux ] || die "npz runs on Linux only: EROFS and overlayfs are Linux kernel filesystems."

for t in curl tar sha256sum; do
    have "$t" || die "\`$t\` is missing, and this script needs it."
done

# Two names for the same architecture, because the formats never agreed: the
# .deb and the tarball say amd64, the .rpm and the Arch package say x86_64.
case "$(uname -m)" in
    x86_64|amd64)  ARCH_DEB=amd64; ARCH_RPM=x86_64 ;;
    aarch64|arm64) ARCH_DEB=arm64; ARCH_RPM=aarch64 ;;
    *) die "no release for $(uname -m): the sources are still there, $PROJECT" ;;
esac

# ── which version ────────────────────────────────────────────────────────────
#
# `releases/latest` is a redirect to the real tag, and reading it costs one
# unauthenticated request. GitHub's API would have said the same thing in JSON,
# but it allows 60 requests per hour per IP address: behind an office NAT you
# often find that budget already spent by somebody else.
latest_version() {
    curl -fsSL -o /dev/null -w '%{url_effective}' "$PROJECT/releases/latest" \
        | sed 's#.*/tag/v##'
}

VERSION="${NPZ_VERSION:-$(latest_version)}"
[ -n "$VERSION" ] || die "cannot tell which version is the latest. Try again, or pass NPZ_VERSION=…"
DOWNLOAD="$PROJECT/releases/download/v$VERSION"

printf '\033[1mnpz %s · %s\033[0m\n' "$VERSION" "$ARCH_DEB"

# ── what installs it ─────────────────────────────────────────────────────────
#
# The order is not alphabetical: it looks first for the package manager that
# *owns* the system. On a Manjaro box with `apt` installed by accident, pacman
# is still the right answer.
if [ -n "${NPZ_METHOD:-}" ]; then
    METHOD="$NPZ_METHOD"
elif have pacman; then METHOD=arch
elif have apt-get; then METHOD=deb
elif have dnf || have zypper; then METHOD=rpm
else METHOD=tarball
fi

# The piece of the name that tells the right asset from the other eight — not
# the whole name. Composing that here would mean keeping the conventions of
# three packaging formats in mind — `npz_0.2.7-1_amd64.deb`,
# `npz-0.2.7-1.x86_64.rpm` — and getting one of them wrong would mean a broken
# installer, found by users rather than by us.
case "$METHOD" in
    arch)    PATTERN="$ARCH_RPM\.pkg\.tar\.zst$" ;;
    deb)     PATTERN="_$ARCH_DEB\.deb$" ;;
    rpm)     PATTERN="\.$ARCH_RPM\.rpm$" ;;
    tarball) PATTERN="linux-$ARCH_DEB\.tar\.gz$" ;;
    *)       die "NPZ_METHOD=$METHOD does not exist: use arch, deb, rpm or tarball." ;;
esac

# ── download, verify, install ────────────────────────────────────────────────

WORK=$(mktemp -d)
# On error paths too, and on Ctrl-C: a script that leaves rubbish in /tmp leaves
# it there forever, because nobody ever goes looking for it.
trap 'rm -rf "$WORK"' EXIT INT TERM

# `SHA256SUMS` is fetched **first**, and it does two jobs: it says what the
# assets of this release are really called — it is the list that names them all
# — and right after that it says whether what arrived is what was published.
# Its name is the only one this script has to know.
info "reading the release manifest"
curl -fsSL --proto '=https' --tlsv1.2 -o "$WORK/SHA256SUMS" "$DOWNLOAD/SHA256SUMS" \
    || die "v$VERSION has no SHA256SUMS: stopping, rather than installing something unverified."

FILE=$(awk '{print $2}' "$WORK/SHA256SUMS" | sed 's|^\*||' | grep -E "$PATTERN" | head -n 1)
[ -n "$FILE" ] || die "v$VERSION has no $METHOD asset for $(uname -m). Try NPZ_METHOD=tarball."

info "downloading $FILE"
curl -fsSL --proto '=https' --tlsv1.2 -o "$WORK/$FILE" "$DOWNLOAD/$FILE" \
    || die "cannot download $FILE."

# `--ignore-missing` because SHA256SUMS covers the whole release and only one
# file is here. The check is not a nicety: `curl | sh` already asked you to
# trust it once, and this is the point where it can stop asking.
info "verifying the checksum"
( cd "$WORK" && sha256sum -c --ignore-missing --quiet SHA256SUMS ) \
    || die "checksum mismatch. What was downloaded is not what was published: not installing it."

# sudo is named before it is used, so whoever is reading knows what is about to
# happen; if it is missing, say so instead of failing inside somebody else's
# command.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    have sudo || die "root privileges are needed and \`sudo\` is not here. Run it as root, or use NPZ_METHOD=tarball."
    SUDO=sudo
fi

case "$METHOD" in
    arch) info "pacman -U"; $SUDO pacman -U --noconfirm "$WORK/$FILE" ;;
    # `apt install ./file` and not `dpkg -i`: apt resolves the dependencies,
    # dpkg merely complains about them and leaves the package half installed.
    deb)  info "apt install"; $SUDO apt-get install -y "$WORK/$FILE" ;;
    rpm)  if have dnf; then info "dnf install"; $SUDO dnf install -y "$WORK/$FILE"
          else info "zypper install"; $SUDO zypper --non-interactive install --allow-unsigned-rpm "$WORK/$FILE"; fi ;;
    tarball)
        tar xzf "$WORK/$FILE" -C "$WORK" npz
        WHERE=/usr/local/bin
        info "installing into $WHERE"
        $SUDO install -m 0755 "$WORK/npz" "$WHERE/npz"
        info "to remove it: $SUDO rm $WHERE/npz" ;;
esac

# ── what is still missing ────────────────────────────────────────────────────

printf '\n  [%s] npz %s installed.\n' "$(green ok)" "$VERSION"

MISSING=""
for t in $NEEDED; do
    have "$t" || MISSING="$MISSING $t"
done

if [ -n "$MISSING" ]; then
    printf '\n  [%s] still missing:%s\n' "$(red warning)" "$MISSING"
    info "npz uses these to build and mount the image, and will not run without them."
    if have pacman; then      info "sudo pacman -S erofs-utils erofsfuse fuse-overlayfs fuse3"
    elif have apt-get; then   info "sudo apt install erofs-utils fuse-overlayfs fuse3"
    elif have dnf; then       info "sudo dnf install erofs-utils fuse-overlayfs fuse3"
    elif have zypper; then    info "sudo zypper install erofs-utils fuse-overlayfs fuse3"
    fi
    # `erofsfuse` is a package of its own only on Arch, where the line above
    # already names it. Elsewhere it was never checked against the repositories,
    # and promising a package name that does not exist is worse than silence.
    info "on some distributions erofsfuse is a separate package, or missing entirely."
fi

printf '\n  To start, inside a project:  npz install\n'
printf '  The way out, at any time:    npz detach\n\n'
