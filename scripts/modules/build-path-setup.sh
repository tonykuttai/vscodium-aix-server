#!/bin/bash
# modules/build-path-setup.sh
# Setup PATH for VSCodium remote CLI

set -e

BUILDDIR="$1"
SERVER_DIR="$2"

if [[ -z "$SERVER_DIR" ]]; then
    echo "Usage: $0 <build_directory> <server_directory>"
    exit 1
fi

MODULE_NAME="path-setup"
CLI_DIR="$SERVER_DIR/bin/remote-cli"
BASHRC_FILE="$HOME/.bashrc"

echo "Setting up VSCodium CLI in PATH..."
echo "Server directory: $SERVER_DIR"
echo "CLI directory: $CLI_DIR"

# Check if already setup
if [[ -f "$SERVER_DIR/.path-setup-patched" ]]; then
    echo "PATH setup already configured"
    exit 0
fi

# Verify CLI exists
if [[ ! -f "$CLI_DIR/codium" ]]; then
    echo "ERROR: Remote CLI not found at $CLI_DIR/codium"
    echo "Platform-override patch should be applied first"
    exit 1
fi

# Check if PATH already contains CLI
if echo "$PATH" | grep -q "$CLI_DIR"; then
    echo "OK VSCodium CLI already in PATH"
else
    echo "Adding VSCodium CLI to PATH..."
    
    BASHRC_TARGET="$BASHRC_FILE"
    if [[ -f "$HOME/.bashrc.mine" ]]; then
        BASHRC_TARGET="$HOME/.bashrc.mine"
    fi
    
    PATH_EXPORT="export PATH=\"$CLI_DIR:\$PATH\""
    
    if ! grep -F "$CLI_DIR" "$BASHRC_TARGET" >/dev/null 2>&1; then
        echo "" >> "$BASHRC_TARGET"
        echo "# VSCodium Server CLI - Added by AIX build scripts" >> "$BASHRC_TARGET"
        echo "$PATH_EXPORT" >> "$BASHRC_TARGET"
        echo "OK Added VSCodium CLI to PATH in $BASHRC_TARGET"
    else
        echo "OK VSCodium CLI PATH already in $BASHRC_TARGET"
    fi
fi

# Test CLI
echo "Testing VSCodium CLI..."
if "$CLI_DIR/codium" --version >/dev/null 2>&1; then
    echo "OK VSCodium CLI working"
else
    echo "⚠ VSCodium CLI test failed (may be normal if server not running)"
fi

# Mark as setup
touch "$SERVER_DIR/.path-setup-patched"
cat > "$SERVER_DIR/.path-setup-patched" << EOF
AIX PATH Setup Applied
Date: $(date)
CLI Directory: $CLI_DIR
Added to: $BASHRC_TARGET
EOF

echo "SUCCESS: PATH setup completed"
echo ""
echo "To use 'codium' command, restart your shell or run:"
echo "  source $BASHRC_TARGET"

exit 0