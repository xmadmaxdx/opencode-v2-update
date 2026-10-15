#!/usr/bin/env bash
# opencode-v2-update - upgrade an existing OpenCode 2.x install (macOS / Linux)
#
# Resolves the newest 2.x and replaces the binary in place. It exists because
# the built-in `opencode upgrade` needs bash tooling that is not always
# present on Windows, and because some package managers leave a second copy of
# OpenCode behind - which is what causes "Background service failed to start".

set -uo pipefail

APP="opencode"
INSTALL_DIR="${OPENCODE_INSTALL_DIR:-$HOME/.opencode/bin}"
VERSION_API="https://opencode.ai/update/api/latest/cli/npm"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; CYAN=$'\033[36m'; NC=$'\033[0m'
step() { printf '\n==> %s%s%s\n' "$CYAN" "$1" "$NC"; }
ok()   { printf '    [ok]   %s%s%s\n' "$GREEN" "$1" "$NC"; }
info() { printf '    [info] %s%s%s\n' "$DIM" "$1" "$NC"; }
warn() { printf '    [warn] %s%s%s\n' "$YELLOW" "$1" "$NC"; }
fail() { printf '    [FAIL] %s%s%s\n' "$RED" "$1" "$NC"; }

usage() {
    cat <<'EOF'
opencode-v2-update upgrader (macOS / Linux)

Usage:
    ./Upgrade-OpenCode.sh [options]

Options:
    -v, --version <x.y.z>  Upgrade to a specific version
        --check           Report whether an update exists, change nothing
    -h, --help             Show this help

Environment:
    OPENCODE_INSTALL_DIR   Install directory (default: ~/.opencode/bin)
EOF
}

check_only="false"
requested_version=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -v|--version) requested_version="${2#v}"; shift 2 ;;
        --check) check_only="true"; shift ;;
        *) warn "unknown option '$1'"; shift ;;
    esac
done

detect_target() {
    local raw_os arch
    raw_os="$(uname -s)"
    case "$raw_os" in
        Darwin*) os="darwin" ;;
        Linux*)  os="linux" ;;
        *) fail "unsupported operating system: $raw_os"; exit 1 ;;
    esac
    arch="$(uname -m)"
    case "$arch" in
        arm64|aarch64) arch="arm64" ;;
        x86_64|amd64)  arch="x64" ;;
        *) fail "unsupported CPU architecture: $arch"; exit 1 ;;
    esac
    if [[ "$os" == "darwin" && "$arch" == "x64" ]]; then
        [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" == "1" ]] && arch="arm64"
    fi
    target="$os-$arch"
    if [[ "$os" == "linux" ]]; then
        [[ -f /etc/alpine-release ]] && target="$target-musl"
        if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
            target="$target-musl"
        fi
    fi
    if [[ "$arch" == "x64" ]]; then
        if [[ "$os" == "linux" ]]; then
            grep -qwi avx2 /proc/cpuinfo 2>/dev/null || target="$target-baseline"
        else
            [[ "$(sysctl -n hw.optional.avx2_0 2>/dev/null || echo 0)" != "1" ]] && target="$target-baseline"
        fi
    fi
}

binary_version() {
    local out
    out="$("$1" --version 2>/dev/null)" || return 1
    out="${out##* }"
    printf '%s' "${out#v}"
}

step "Checking the current install"
detect_target

if [[ -x "$INSTALL_DIR/$APP" ]]; then
    current="$(binary_version "$INSTALL_DIR/$APP")"
elif command -v "$APP" >/dev/null 2>&1; then
    current="$(binary_version "$(command -v "$APP")")"
else
    current=""
fi

if [[ -z "$current" ]]; then
    fail "no OpenCode install found. Run install.sh first."
    exit 1
fi
if [[ "${current%%.*}" == "1" ]]; then
    fail "that is OpenCode 1.x ($current). 1.x and 2.x cannot upgrade into each other - run install.sh instead."
    exit 1
fi
ok "installed version: $current  ($target)"

step "Looking up the newest 2.x"
body="$(curl -fsSL --max-time 30 "$VERSION_API" 2>/dev/null)" || body=""
if [[ "$body" =~ \"version\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    latest="${BASH_REMATCH[1]}"
else
    body="$(curl -fsSL --max-time 30 "https://registry.npmjs.org/@opencode%2Fcli/latest" 2>/dev/null)" || body=""
    if [[ "$body" =~ \"version\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
        latest="${BASH_REMATCH[1]}"
    else
        latest=""
    fi
fi

if [[ -z "$latest" ]]; then
    fail "could not determine the latest version"
    exit 1
fi

target_version="${requested_version:-$latest}"
if [[ "$target_version" == "$current" ]]; then
    ok "already up to date at $current"
    exit 0
fi

if [[ "$check_only" == "true" ]]; then
    ok "update available: $current -> $target_version"
    exit 0
fi

pkg="cli-$target"
code="$(curl -s -o /dev/null -w '%{http_code}' \
        "https://registry.npmjs.org/@opencode%2F${pkg}/${target_version}")"
if [[ "$code" != "200" ]]; then
    fail "version $target_version is not published for $target"
    exit 1
fi

step "Upgrading to $target_version"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/opencode-upgrade-XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT

if ! curl -fL --progress-bar -o "$tmp/cli.tgz" \
    "https://registry.npmjs.org/@opencode/${pkg}/-/${pkg}-${target_version}.tgz"; then
    fail "download failed"
    exit 1
fi
tar -xzf "$tmp/cli.tgz" -C "$tmp" || { fail "could not unpack"; exit 1; }

src="$tmp/package/bin/$APP"
[[ -f "$src" ]] || { fail "expected $src inside the tarball"; exit 1; }

mkdir -p "$INSTALL_DIR" || { fail "cannot create $INSTALL_DIR"; exit 1; }
dest="$INSTALL_DIR/$APP"
if [[ -f "$dest" ]] && ! mv -f "$dest" "$dest.old.$$" 2>/dev/null; then
    fail "$dest is in use - close any running opencode window and re-run"
    exit 1
fi
mv -f "$src" "$dest" || { fail "could not move the new binary into place"; exit 1; }
chmod 755 "$dest"
rm -f "$dest.old.$$" 2>/dev/null || true

reported="$(binary_version "$dest")"
if [[ "$reported" != "$target_version" ]]; then
    fail "expected $target_version but the new binary reports '$reported'"
    exit 1
fi

ok "upgraded: $current -> $reported"
printf '\n    %sReopen your terminal.%s\n\n' "$DIM" "$NC"