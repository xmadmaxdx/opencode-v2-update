#!/usr/bin/env bash
# opencode-v2-update - installer for macOS and Linux
#
# Tries four install methods in order and keeps the first one that produces a
# working binary:
#
#   1. direct   - per-target npm tarball into ~/.opencode/bin  (all platforms)
#   2. npm      - npm install -g @opencode/cli
#   3. bun      - bun install -g --trust @opencode/cli
#   4. brew     - brew install anomalyco/tap/opencode-v2       (macOS/Linux)
#
# OpenCode 1.x is removed by default so the two products cannot both claim the
# `opencode` command. Pass --keep-legacy to leave 1.x alone.

set -uo pipefail

APP="opencode"
INSTALL_DIR="${OPENCODE_INSTALL_DIR:-$HOME/.opencode/bin}"
# 1.x and 2.x are DIFFERENT products with DIFFERENT identifiers in every
# package manager. Getting these mixed up is the usual reason a machine ends
# up with two `opencode` commands.
LEGACY_NPM_PKG="opencode-ai"                  # 1.x npm / bun
MODERN_NPM_PKG="@opencode/cli"                # 2.x npm / bun
LEGACY_BREW_FORMULA="opencode"                # 1.x  (anomalyco/tap/opencode)
MODERN_BREW_FORMULA="opencode-v2"             # 2.x  (anomalyco/tap/opencode-v2)
VERSION_API="https://opencode.ai/update/api/latest/cli/npm"
CONFIG_DIR="$HOME/.config/opencode"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; CYAN=$'\033[36m'; NC=$'\033[0m'

step()  { printf '\n==> %s%s%s\n' "$CYAN" "$1" "$NC"; }
ok()    { printf '    [ok]   %s%s%s\n' "$GREEN" "$1" "$NC"; }
info()  { printf '    [info] %s%s%s\n' "$DIM" "$1" "$NC"; }
warn()  { printf '    [warn] %s%s%s\n' "$YELLOW" "$1" "$NC"; }
fail()  { printf '    [FAIL] %s%s%s\n' "$RED" "$1" "$NC"; }

usage() {
    cat <<'EOF'
opencode-v2-update installer (macOS / Linux)

Usage:
    ./install.sh [options]

Options:
    -v, --version <x.y.z>  Install a specific version (default: newest 2.x)
        --method <name>   Force one method: direct, npm, bun, brew, auto
                          (default: auto, which tries them in order)
        --keep-legacy     Do NOT remove OpenCode 1.x (default: it is removed)
        --skip-config     Install the binary only; do not touch ~/.config/opencode
        --replace-config  Let the bundled config overwrite yours (default: additive)
        --no-modify-path  Do not edit .zshrc / .bashrc / .profile
        --print-logs      Print this help as well
    -h, --help             Show this help

Environment:
    OPENCODE_INSTALL_DIR   Override the install directory
                          (default: ~/.opencode/bin)
EOF
}

requested_version=""
force_method="auto"
keep_legacy="false"
skip_config="false"
replace_config="false"
no_modify_path="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -v|--version)
            if [[ -n "${2:-}" ]]; then requested_version="${2#v}"; shift 2
            else fail "--version needs an argument"; exit 1; fi ;;
        --method)
            if [[ -n "${2:-}" ]]; then force_method="$2"; shift 2
            else fail "--method needs an argument"; exit 1; fi ;;
        --keep-legacy)  keep_legacy="true"; shift ;;
        --skip-config)  skip_config="true"; shift ;;
        --replace-config) replace_config="true"; shift ;;
        --no-modify-path) no_modify_path="true"; shift ;;
        *) warn "unknown option '$1'"; shift ;;
    esac
done

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
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

    # Rosetta: an x64 shell on an Apple Silicon Mac reports x86_64.
    if [[ "$os" == "darwin" && "$arch" == "x64" ]]; then
        local translated
        translated="$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)"
        [[ "$translated" == "1" ]] && arch="arm64"
    fi

    target="$os-$arch"

    # musl (Alpine and friends) needs its own build.
    if [[ "$os" == "linux" ]]; then
        if [[ -f /etc/alpine-release ]]; then target="$target-musl"; fi
        if command -v ldd >/dev/null 2>&1; then
            if ldd --version 2>&1 | grep -qi musl; then target="$target-musl"; fi
        fi
    fi

    # x64 CPUs without AVX2 need the baseline build.
    if [[ "$arch" == "x64" ]]; then
        needs_baseline="false"
        if [[ "$os" == "linux" ]]; then
            grep -qwi avx2 /proc/cpuinfo 2>/dev/null || needs_baseline="true"
        else
            local avx2
            avx2="$(sysctl -n hw.optional.avx2_0 2>/dev/null || echo 0)"
            [[ "$avx2" != "1" ]] && needs_baseline="true"
        fi
        [[ "$needs_baseline" == "true" ]] && target="$target-baseline"
    fi
}

# ---------------------------------------------------------------------------
# Version resolution - the official endpoint, with the npm registry as backup
# ---------------------------------------------------------------------------
resolve_version() {
    if [[ -n "$requested_version" ]]; then
        target_version="$requested_version"
        ok "using requested version $target_version"
        return
    fi

    step "Finding the newest OpenCode 2.x"
    local body
    # Parsed with bash regex rather than sed/awk so the script needs nothing
    # beyond curl and tar.
    body="$(curl -fsSL --max-time 30 "$VERSION_API" 2>/dev/null)" || body=""
    if [[ "$body" =~ \"version\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
        target_version="${BASH_REMATCH[1]}"
    else
        target_version=""
    fi

    if [[ -z "$target_version" ]]; then
        warn "version API unreachable, trying the npm registry"
        body="$(curl -fsSL --max-time 30 "https://registry.npmjs.org/@opencode%2Fcli/latest" 2>/dev/null)" || body=""
        if [[ "$body" =~ \"version\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
            target_version="${BASH_REMATCH[1]}"
        else
            target_version=""
        fi
    fi

    if [[ -z "$target_version" ]]; then
        fail "could not determine the latest version"
        fail "re-run with --version <x.y.z> to pin one"
        exit 1
    fi
    if [[ ! "$target_version" =~ ^2\. ]]; then
        fail "resolved '$target_version', which is not a 2.x release"
        exit 1
    fi
    ok "latest is $target_version"
}

# ---------------------------------------------------------------------------
# Preflight - fail before touching anything
# ---------------------------------------------------------------------------
preflight() {
    step "Preflight"
    for tool in curl tar; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            fail "'$tool' is required but was not found"
            exit 1
        fi
    done
    ok "curl and tar are available"

    if ! curl -fsS --max-time 15 -o /dev/null "https://$host_for_opencode" 2>/dev/null; then
        : # handled by the registry probe below
    fi
    if ! curl -fsSL --max-time 20 -o /dev/null "https://registry.npmjs.org/@opencode%2Fcli/latest" 2>/dev/null; then
        fail "no internet connection to the npm registry"
        exit 1
    fi
    ok "internet reachable"
    ok "target: $target ($os, $arch)"
}

# ---------------------------------------------------------------------------
# Method 1 - direct tarball
# ---------------------------------------------------------------------------
install_direct() {
    local pkg="cli-$target" url http_code
    url="https://registry.npmjs.org/@opencode%2F${pkg}/${target_version}"

    http_code="$(curl -s -o /dev/null -w '%{http_code}' "$url")"
    if [[ "$http_code" == "404" ]]; then
        # Older clients used the @opencode-ai scope.
        local legacy_url="https://registry.npmjs.org/@opencode-ai%2F${pkg}/${target_version}"
        http_code="$(curl -s -o /dev/null -w '%{http_code}' "$legacy_url")"
        [[ "$http_code" == "200" ]] || { fail "$target_version is not published for $target"; return 1; }
        warn "$target has no @opencode/cli build; falling back to @opencode-ai/cli"
    elif [[ "$http_code" != "200" ]]; then
        fail "npm registry returned HTTP $http_code for $target"
        return 1
    fi

    ok "$target_version is published for $target"

    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/opencode-install-XXXXXX")" || return 1
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN

    local tgz="$tmp/cli-$target-$target_version.tgz"
    info "downloading $pkg"
    if ! curl -fL --progress-bar -o "$tgz" \
        "https://registry.npmjs.org/@opencode/${pkg}/-/${pkg}-${target_version}.tgz"; then
        fail "download failed"
        return 1
    fi

    tar -xzf "$tgz" -C "$tmp" || { fail "could not unpack the tarball"; return 1; }

    local src="$tmp/package/bin/$APP"
    if [[ ! -f "$src" ]]; then
        fail "expected the binary at package/bin/$APP"
        return 1
    fi

    mkdir -p "$INSTALL_DIR" || { fail "cannot create $INSTALL_DIR"; return 1; }
    # Replace atomically-ish; a running binary cannot be overwritten on some systems.
    local dest="$INSTALL_DIR/$APP"
    if [[ -f "$dest" ]] && ! mv -f "$dest" "$dest.old.$$" 2>/dev/null; then
        fail "$dest is in use - close any running opencode and re-run"
        return 1
    fi
    mv -f "$src" "$dest" || { fail "could not move the binary into $INSTALL_DIR"; return 1; }
    chmod 755 "$dest" || true
    rm -f "$dest.old.$$" 2>/dev/null || true

    # The upstream installer also drops an `opencode2` alias.
    cat > "$INSTALL_DIR/opencode2" <<EOF
#!/bin/sh
exec "\$(dirname "\$0")/$APP" "\$@"
EOF
    chmod 755 "$INSTALL_DIR/opencode2"

    ok "installed to $dest"
    INSTALLED_VIA="direct"
    return 0
}

# ---------------------------------------------------------------------------
# Methods 2-4 - package managers
# ---------------------------------------------------------------------------
run_cmd() {
    local label="$1"; shift
    info "trying $label: $*"
    if "$@" >/dev/null 2>&1; then return 0; fi
    return 1
}

install_npm() {
    command -v npm >/dev/null 2>&1 || { info "npm not installed"; return 1; }
    run_cmd "npm" npm install -g "$MODERN_NPM_PKG" || { fail "npm install failed"; return 1; }
    ok "installed via npm"
    INSTALLED_VIA="npm"
    return 0
}

install_bun() {
    command -v bun >/dev/null 2>&1 || { info "bun not installed"; return 1; }
    run_cmd "bun" bun install -g --trust "$MODERN_NPM_PKG" || { fail "bun install failed"; return 1; }
    ok "installed via bun"
    INSTALLED_VIA="bun"
    return 0
}

install_brew() {
    command -v brew >/dev/null 2>&1 || { info "brew not installed"; return 1; }
    run_cmd "brew" brew install "anomalyco/tap/$MODERN_BREW_FORMULA" || { fail "brew install failed"; return 1; }
    ok "installed via brew (formula $MODERN_BREW_FORMULA)"
    INSTALLED_VIA="brew"
    return 0
}

# ---------------------------------------------------------------------------
# Verification - a method only counts if the binary works
# ---------------------------------------------------------------------------
installed_binary_path() {
    if [[ -x "$INSTALL_DIR/$APP" ]]; then printf '%s' "$INSTALL_DIR/$APP"; return 0; fi
    local found
    found="$(command -v "$APP" 2>/dev/null)" || return 1
    printf '%s' "$found"
}

binary_version() {
    # Pure bash - no awk/sed dependency.
    local out
    out="$("$1" --version 2>/dev/null)" || return 1
    out="${out##* }"
    printf '%s' "${out#v}"
}

verify_install() {
    step "Verifying"
    local bin reported
    bin="$(installed_binary_path)" || { fail "no opencode binary on PATH or in $INSTALL_DIR"; return 1; }
    ok "binary: $bin"
    reported="$(binary_version "$bin")"
    if [[ -z "$reported" ]]; then fail "the binary did not report a version"; return 1; fi
    if [[ "$reported" != "$target_version" ]]; then
        fail "expected $target_version but it reports $reported"
        return 1
    fi
    ok "reports version $reported"
    FINAL_BINARY="$bin"
    return 0
}

# ---------------------------------------------------------------------------
# OpenCode 1.x removal (on by default)
# ---------------------------------------------------------------------------
brew_has_formula() {
    command -v brew >/dev/null 2>&1 || return 1
    brew list --formula 2>/dev/null | grep -Fxq "$1"
}

bun_has_pkg() {
    command -v bun >/dev/null 2>&1 || return 1
    bun pm ls -g 2>/dev/null | grep -qF "\"$1\""
}

remove_legacy() {
    step "OpenCode 1.x"
    if [[ "$keep_legacy" == "true" ]]; then
        info "--keep-legacy given, leaving 1.x alone"
        warn "1.x and 2.x both register an 'opencode' command and will conflict"
        return 0
    fi

    local found="false"

    # --- npm ---
    if command -v npm >/dev/null 2>&1 && npm ls -g --depth=0 2>/dev/null | grep -q "$LEGACY_NPM_PKG@"; then
        found="true"
        if npm uninstall -g "$LEGACY_NPM_PKG" >/dev/null 2>&1; then
            ok "removed npm package $LEGACY_NPM_PKG (1.x)"
        else
            warn "could not remove $LEGACY_NPM_PKG - run: npm uninstall -g $LEGACY_NPM_PKG"
        fi
    fi

    # --- bun. 1.x and 2.x differ only by package name: opencode-ai vs @opencode/cli
    if bun_has_pkg "$LEGACY_NPM_PKG"; then
        found="true"
        if bun remove -g "$LEGACY_NPM_PKG" >/dev/null 2>&1 || bun uninstall -g "$LEGACY_NPM_PKG" >/dev/null 2>&1; then
            ok "removed bun package $LEGACY_NPM_PKG (1.x)"
        else
            warn "could not remove the bun package - run: bun remove -g $LEGACY_NPM_PKG"
        fi
    fi

    # --- brew. The 1.x formula is `opencode`; the 2.x one is `opencode-v2`,
    #     so removing by formula name can never touch a 2.x brew install.
    if brew_has_formula "$LEGACY_BREW_FORMULA"; then
        found="true"
        if brew uninstall "$LEGACY_BREW_FORMULA" >/dev/null 2>&1; then
            ok "removed brew formula $LEGACY_BREW_FORMULA (1.x)"
        else
            warn "could not remove it - run: brew uninstall $LEGACY_BREW_FORMULA"
        fi
    fi

    # --- manual binary from the curl installer, sitting in our own dir
    local legacy_exe="$INSTALL_DIR/$APP"
    if [[ -x "$legacy_exe" ]]; then
        local ver
        ver="$("$legacy_exe" --version 2>/dev/null | grep -oE 'v?1\.[0-9]+\.[0-9]+' | head -n1)"
        if [[ -n "$ver" ]]; then
            found="true"
            local grave="$INSTALL_DIR/opencode-1x-$(date +%Y%m%d-%H%M%S)"
            if mv "$legacy_exe" "$grave" 2>/dev/null; then
                ok "quarantined 1.x binary to $grave (never deleted)"
            else
                warn "1.x binary is in use at $legacy_exe - close it and re-run"
            fi
        fi
    fi

    [[ "$found" == "false" ]] && ok "no OpenCode 1.x install found"
    return 0
}

# ---------------------------------------------------------------------------
# Competing installs - two OpenCodes fight over the service port
# ---------------------------------------------------------------------------
remove_competing() {
    step "Competing installs"
    local keep_dir="$INSTALL_DIR/"
    local shim_dir
    shim_dir="$(npm prefix -g 2>/dev/null)/bin" || shim_dir=""

    if [[ "$INSTALLED_VIA" == "direct" ]]; then
        if command -v npm >/dev/null 2>&1 && npm ls -g --depth=0 2>/dev/null | grep -q "$MODERN_NPM_PKG@"; then
            warn "an npm $MODERN_NPM_PKG is also installed and would shadow this one"
            if npm uninstall -g "$MODERN_NPM_PKG" >/dev/null 2>&1; then
                ok "removed the npm copy so only one OpenCode remains"
            else
                warn "remove it by hand:  npm uninstall -g $MODERN_NPM_PKG"
            fi
        else
            ok "single install confirmed"
        fi
    else
        warn "$INSTALLED_VIA owns this install; do not also run the direct one"
        warn "two OpenCodes share the background service port and will conflict"
    fi
    : "$shim_dir"
}

# ---------------------------------------------------------------------------
# PATH
# ---------------------------------------------------------------------------
add_to_path() {
    step "Updating PATH"
    if [[ "$no_modify_path" == "true" ]]; then
        info "--no-modify-path given"
        return 0
    fi
    if [[ "$INSTALLED_VIA" != "direct" ]]; then
        info "$INSTALLED_VIA manages PATH itself"
        return 0
    fi
    case ":$PATH:" in
        *":$INSTALL_DIR:"*) ok "$INSTALL_DIR already on PATH"; return 0 ;;
    esac

    local candidates=()
    case "$(basename "${SHELL:-bash}")" in
        zsh)  candidates=("${ZDOTDIR:-$HOME}/.zshrc" "$HOME/.zshenv") ;;
        fish) candidates=("$HOME/.config/fish/config.fish") ;;
        *)    candidates=("$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile") ;;
    esac

    local f
    for f in "${candidates[@]}"; do
        [[ -f "$f" ]] || continue
        if grep -Fq "$INSTALL_DIR" "$f" 2>/dev/null; then ok "$INSTALL_DIR already in $f"; return 0; fi
        if [[ "$(basename "${SHELL:-bash}")" == "fish" ]]; then
            printf '\n# opencode\nfish_add_path "%s"\n' "$INSTALL_DIR" >> "$f"
        else
            printf '\n# opencode\nexport PATH="%s:$PATH"\n' "$INSTALL_DIR" >> "$f"
        fi
        ok "added to $f"
        info "close and reopen your terminal for this to take effect"
        return 0
    done

    warn "could not find a shell rc file to edit"
    warn "add it yourself:  export PATH=\"$INSTALL_DIR:\$PATH\""
}

# ---------------------------------------------------------------------------
# Config - additive only
# ---------------------------------------------------------------------------
install_config() {
    step "Config"
    if [[ "$skip_config" == "true" ]]; then
        info "--skip-config given, leaving $CONFIG_DIR alone"
        return 0
    fi

    local here payload
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    payload="$here/payload/config"
    if [[ ! -d "$payload" ]]; then
        warn "payload/config not found next to this script - skipping"
        return 0
    fi

    if [[ -d "$CONFIG_DIR" ]]; then
        local backup="$HOME/.config/opencode.backup-$(date +%Y%m%d-%H%M%S)"
        if cp -R "$CONFIG_DIR" "$backup" 2>/dev/null; then
            ok "backed up to $backup"
        else
            warn "could not back up $CONFIG_DIR"
        fi
    fi
    mkdir -p "$CONFIG_DIR"

    if [[ "$replace_config" == "true" ]]; then
        warn "--replace-config given: the bundled config will overwrite existing files"
        if command -v rsync >/dev/null 2>&1; then
            rsync -a --delete --exclude node_modules --exclude __pycache__ \
                  "$payload/" "$CONFIG_DIR/" && ok "config replaced"
        else
            warn "rsync not found; copying without --delete (stale files may remain)"
            cp -R "$payload/." "$CONFIG_DIR/" && ok "config copied"
        fi
        return 0
    fi

    local added=0 kept=0 f rel dest
    while IFS= read -r -d '' f; do
        rel="${f#"$payload"/}"
        dest="$CONFIG_DIR/$rel"
        if [[ -e "$dest" ]]; then kept=$((kept+1)); continue; fi
        mkdir -p "$(dirname "$dest")"
        cp "$f" "$dest" && added=$((added+1))
    done < <(find "$payload" -type f \
                -not -path "*/node_modules/*" \
                -not -path "*/__pycache__/*" -print0)

    ok "added $added file(s) that were missing"
    if [[ $kept -gt 0 ]]; then ok "left your existing $kept file(s) untouched"; fi
    info "your skills, agents, MCP servers, providers and stored data were not modified"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    host_for_opencode="opencode.ai"
    detect_target
    resolve_version
    preflight

    local order=("$force_method")
    if [[ "$force_method" == "auto" ]]; then
        order=(direct npm bun brew)
    fi

    step "Installing OpenCode $target_version"
    local m
    for m in "${order[@]}"; do
        info "--- method: $m ---"
        case "$m" in
            direct) install_direct ;;
            npm)    install_npm ;;
            bun)    install_bun ;;
            brew)   install_brew ;;
            *) fail "unknown method '$m'"; exit 1 ;;
        esac
        if [[ $? -eq 0 ]]; then
            if verify_install; then
                break
            fi
            warn "$m did not produce a working binary; trying the next method"
        fi
        [[ "$force_method" != "auto" ]] && { fail "method '$m' failed"; exit 1; }
    done

    if [[ -z "${FINAL_BINARY:-}" ]]; then
        fail "every install method failed"
        fail "tried: direct, npm, bun, brew"
        fail "if you are behind a proxy, set HTTPS_PROXY and re-run"
        exit 1
    fi

    ok "installed via $INSTALLED_VIA"

    remove_legacy
    remove_competing
    install_config
    add_to_path

    step "Done"
    printf '    %sopencode%s is ready. Reopen your terminal, then run:\n\n' "$CYAN" "$NC"
    printf '        cd <project>   # open a directory\n'
    printf '        opencode       # start\n\n'
    printf '    %sDocs: %shttps://opencode.ai/v2/docs%s\n' "$DIM" "$NC" "$DIM$NC"
}

# Only run when executed. Sourcing exposes the functions for testing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi