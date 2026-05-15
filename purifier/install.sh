#!/usr/bin/env bash
set -euo pipefail

PURIFIER_SRC="$(dirname "$(realpath "$0")")"

echo "purifier installer"
echo "=================="
echo ""

# Install to ~/.local/bin
INSTALL_DIR="${HOME}/.local/bin"
mkdir -p "${INSTALL_DIR}"

# Create wrapper script
WRAPPER="${INSTALL_DIR}/purifier"
cat > "${WRAPPER}" << WRAPPEREOF
#!/usr/bin/env bash
exec "${PURIFIER_SRC}/purifier" "\$@"
WRAPPEREOF
chmod +x "${WRAPPER}"

echo "Installed to: ${WRAPPER}"
echo ""

# Ensure ~/.local/bin is in PATH
if [[ ":$PATH:" != *":${INSTALL_DIR}:"* ]]; then
    echo "NOTE: Add ${INSTALL_DIR} to your PATH:"
    echo "  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
    echo ""
    echo "Add the above line to ~/.bashrc or ~/.bash_profile."
    echo ""
fi

echo "Next steps:"
echo "  1. Load overlay module:       sudo modprobe overlay"
echo "  2. Setup passwordless sudo:   purifier setup-sudo"
echo "  3. Start a session:           purifier init /path/to/project"
echo ""
echo "Done."
