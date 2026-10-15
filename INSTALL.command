#!/usr/bin/env bash
# Double-click entry point for macOS. Finder runs this from Terminal and keeps
# the window open so the result can be read.
#
# Equivalent of INSTALL.cmd on Windows.

cd "$(dirname "$0")" || exit 1

echo ""
echo "  opencode-v2-update - macOS / Linux installer"
echo "  ------------------------------------------"
echo ""

if ! command -v bash >/dev/null 2>&1; then
    echo "[FAIL] bash is required but was not found."
    echo ""
    read -r -p "Press Return to close."
    exit 1
fi

bash ./install.sh "$@"
STATUS=$?

echo ""
if [[ $STATUS -eq 0 ]]; then
    echo "Setup finished. Run 'opencode' in a new terminal window."
else
    echo "Setup did not finish (exit code $STATUS). See the message above."
fi
echo ""
read -r -p "Press Return to close this window."
exit $STATUS