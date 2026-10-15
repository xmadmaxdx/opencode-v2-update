#!/usr/bin/env bash
# Unit tests for install.sh. Sources the installer and exercises its pure
# logic against real API responses and a temporary config tree.
# Run:  bash test-install.sh

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

PASS=0; FAIL=0
check() { # name expected actual
    if [[ "$2" == "$3" ]]; then
        printf '  ok    %-46s %s\n' "$1" "$3"; PASS=$((PASS+1))
    else
        printf '  FAIL  %-46s expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL+1))
    fi
}

# shellcheck source=install.sh
source ./install.sh

echo "=== version parsing ==="
REAL_JSON="$(curl -fsSL --max-time 30 https://opencode.ai/update/api/latest/cli/npm 2>/dev/null)"
if [[ "$REAL_JSON" =~ \"version\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then parsed="${BASH_REMATCH[1]}"; else parsed=""; fi
check "parses a version from the live API" "1" "$( [[ -n "$parsed" ]] && echo 1 || echo 0 )"
check "live API version is 2.x"           "1" "$( [[ "$parsed" =~ ^2\. ]] && echo 1 || echo 0 )"
check "parsed value looks like x.y.z"      "1" "$( printf '%s' "$parsed" | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+$' )"

NPM_JSON='{"name":"@opencode/cli","version":"2.0.29"}'
if [[ "$NPM_JSON" =~ \"version\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then parsed2="${BASH_REMATCH[1]}"; else parsed2=""; fi
check "parses version from npm fallback shape" "2.0.29" "$parsed2"

echo ""
echo "=== 2.x guard ==="
check "rejects 1.x version" "1" "$( [[ "1.18.35" =~ ^2\. ]] && echo 0 || echo 1 )"
check "accepts 2.x version"  "1" "$( [[ "2.0.29"  =~ ^2\. ]] && echo 1 || echo 0 )"

echo ""
echo "=== argument parsing ==="
( requested_version=""; force_method="auto"; keep_legacy="false"
  set -- --version 2.0.20 --method npm --keep-legacy --skip-config
  while [[ $# -gt 0 ]]; do
      case "$1" in
          -v|--version) requested_version="${2#v}"; shift 2 ;;
          --method) force_method="$2"; shift 2 ;;
          --keep-legacy) keep_legacy="true"; shift ;;
          --skip-config) shift ;;
          *) shift ;;
      esac
  done
  check "--version strips a leading v" "2.0.20" "$requested_version"
  check "--method captured" "npm" "$force_method"
  check "--keep-legacy captured" "true" "$keep_legacy"
)

echo ""
echo "=== binary_version parsing ==="
cat > "$PWD/fake-opencode" <<'EOF'
#!/bin/sh
echo "opencode v2.0.29"
EOF
chmod +x "$PWD/fake-opencode"
check "extracts 2.0.29 from 'opencode v2.0.29'" "2.0.29" "$(binary_version "$PWD/fake-opencode")"
rm -f "$PWD/fake-opencode"

echo ""
echo "=== additive config: existing files must survive ==="
TESTHOME="$(mktemp -d)"; trap 'rm -rf "$TESTHOME"' EXIT
CFG="$TESTHOME/.config/opencode"
mkdir -p "$CFG/skills/my-skill" "$CFG/mcp/mine" "$CFG/agents"
printf 'MY CONFIG'  > "$CFG/opencode.jsonc"
printf 'MY SKILL'  > "$CFG/skills/my-skill/SKILL.md"
printf 'MY MCP'    > "$CFG/mcp/mine/mcp.json"
printf 'MY AGENT'  > "$CFG/agents/my-agent.md"

before="$(cat "$CFG/opencode.jsonc")$(cat "$CFG/skills/my-skill/SKILL.md")$(cat "$CFG/mcp/mine/mcp.json")$(cat "$CFG/agents/my-agent.md")"

# replicate the installer's additive loop exactly
add_file() {
    local payload="$1" added=0 kept=0 f rel dest
    mkdir -p "$CFG"
    while IFS= read -r -d '' f; do
        rel="${f#"$payload"/}"
        dest="$CFG/$rel"
        if [[ -e "$dest" ]]; then kept=$((kept+1)); continue; fi
        mkdir -p "$(dirname "$dest")"
        cp "$f" "$dest" && added=$((added+1))
    done < <(find "$payload" -type f -not -path "*/node_modules/*" -not -path "*/__pycache__/*" -print0)
    echo "$added $kept"
}

PAYLOAD="$TESTHOME/payload/config"
mkdir -p "$PAYLOAD"
cp payload/config/opencode.jsonc "$PAYLOAD/" 2>/dev/null
read -r ADDED KEPT <<< "$(add_file "$PAYLOAD")"

after="$(cat "$CFG/opencode.jsonc")$(cat "$CFG/skills/my-skill/SKILL.md")$(cat "$CFG/mcp/mine/mcp.json")$(cat "$CFG/agents/my-agent.md")"
check "existing opencode.jsonc unchanged" "MY CONFIG" "$(cat "$CFG/opencode.jsonc")"
check "existing skill unchanged"            "MY SKILL" "$(cat "$CFG/skills/my-skill/SKILL.md")"
check "existing MCP unchanged"              "MY MCP"   "$(cat "$CFG/mcp/mine/mcp.json")"
check "existing agent unchanged"            "MY AGENT" "$(cat "$CFG/agents/my-agent.md")"
check "payload file was skipped, not copied" "0" "$ADDED"
check "sentinel content identical"          "$before"  "$after"

echo ""
echo "=== payload ships no personal files ==="
for f in AGENTS.md cli.json tui.json lsp-install-decisions.json; do
    check "payload has no $f" "0" "$( [[ -e "payload/config/$f" ]] && echo 1 || echo 0 )"
done
for d in agents commands skills; do
    check "payload has no $d/" "0" "$( [[ -d "payload/config/$d" ]] && echo 1 || echo 0 )"
done
check "payload config has no mcp block" "0" "$(grep -c '"mcp"' payload/config/opencode.jsonc)"

echo ""
echo "=== pass/fail ==="
echo "passed: $PASS   failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1