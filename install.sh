#!/bin/bash
# Builds Ise.app, puts it in ~/Applications, adds the `ise` command to ~/.local/bin, and restarts the app.
# /ise-setup runs this, and the panel opens at login from that installed copy.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

installed="$HOME/Applications/Ise.app"
mkdir -p "$HOME/Applications" "$HOME/.local/bin"
pkill -x Ise || true
while pgrep -x Ise > /dev/null; do sleep 0.2; done
rm -rf "$installed"
ditto build/Ise.app "$installed"
install -m 755 bin/ise "$HOME/.local/bin/ise"
open "$installed"
echo "Installed and opened $installed"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) echo "The ise command is ready in any terminal." ;;
  *) echo "To use ise in a terminal, add this line to ~/.zshrc: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
