#!/bin/bash
# modules/build-platform-override.sh
# Create platform override system for AIX

set -e

BUILDDIR="$1"
SERVER_DIR="$2"

if [[ -z "$SERVER_DIR" ]]; then
    echo "Usage: $0 <build_directory> <server_directory>"
    exit 1
fi

MODULE_NAME="platform-override"
OVERRIDE_FILE="$SERVER_DIR/aix-platform-override.js"
SERVER_SCRIPT="$SERVER_DIR/bin/codium-server"
CLI_SCRIPT="$SERVER_DIR/bin/remote-cli/codium"

echo "Creating AIX platform override system..."
echo "Server directory: $SERVER_DIR"

# Check if already created
if [[ -f "$SERVER_DIR/.platform-override-patched" ]]; then
    echo "Platform override already installed"
    exit 0
fi

# Create platform override script
echo "Creating platform override script..."
cat > "$OVERRIDE_FILE" << 'EOF'
// AIX Platform Override - intercept process.platform calls
const originalPlatform = process.platform;

Object.defineProperty(process, 'platform', {
    get: function() {
        const stack = new Error().stack;
        
        // For VSCodium components, pretend we're Linux
        if (stack && (stack.includes('ptyHost') || stack.includes('server-main') || stack.includes('deviceid'))) {
            return 'linux';
        }
        
        return originalPlatform;
    },
    configurable: true
});
EOF

echo "OK Created: $OVERRIDE_FILE"

# Update server wrapper
if [[ -f "$SERVER_SCRIPT" ]]; then
    echo "Updating server wrapper..."
    cp "$SERVER_SCRIPT" "$SERVER_SCRIPT.backup"
    
    cat > "$SERVER_SCRIPT" << 'EOF'
#!/bin/bash
NODE_BIN="/opt/nodejs/bin/node"

if [[ ! -x "$NODE_BIN" ]]; then
    echo "ERROR: Node.js not found at $NODE_BIN"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_ROOT="$(dirname "$SCRIPT_DIR")"

# Add node-pty native-libs to LIBPATH with absolute path
export LIBPATH="${SERVER_ROOT}/node_modules/node-pty/lib/native-libs:${LIBPATH}"

SERVER_MAIN=""
if [[ -f "$SCRIPT_DIR/../out/server-main.js" ]]; then
    SERVER_MAIN="$SCRIPT_DIR/../out/server-main.js"
elif [[ -f "$SCRIPT_DIR/../out/vs/server/main.js" ]]; then
    SERVER_MAIN="$SCRIPT_DIR/../out/vs/server/main.js"
else
    echo "ERROR: Server main script not found"
    exit 1
fi

exec "$NODE_BIN" -r "$SCRIPT_DIR/../aix-platform-override.js" "$SERVER_MAIN" "$@"
EOF
    
    chmod +x "$SERVER_SCRIPT"
    echo "OK Updated: $SERVER_SCRIPT"
fi

# Update remote CLI
CLI_DIR="$(dirname "$CLI_SCRIPT")"
mkdir -p "$CLI_DIR"

if [[ -f "$CLI_SCRIPT" ]]; then
    cp "$CLI_SCRIPT" "$CLI_SCRIPT.backup"
fi

VERSION="1.102.24914"
COMMIT="$(basename "$SERVER_DIR")"

cat > "$CLI_SCRIPT" << EOF
#!/usr/bin/env bash
ROOT="\$(dirname "\$(dirname "\$(dirname "\$(readlink -f "\$0")")")")"
APP_NAME="codium"
VERSION="$VERSION"
COMMIT="$COMMIT"
EXEC_NAME="codium"
CLI_SCRIPT="\$ROOT/out/server-cli.js"

NODE_BIN="/opt/nodejs/bin/node"

if [[ ! -x "\$NODE_BIN" ]]; then
    echo "ERROR: Node.js not found at \$NODE_BIN"
    exit 1
fi

exec "\$NODE_BIN" -r "\$ROOT/aix-platform-override.js" "\$CLI_SCRIPT" "\$APP_NAME" "\$VERSION" "\$COMMIT" "\$EXEC_NAME" "\$@"
EOF

chmod +x "$CLI_SCRIPT"
echo "OK Updated: $CLI_SCRIPT"

# Mark as patched
touch "$SERVER_DIR/.platform-override-patched"
cat > "$SERVER_DIR/.platform-override-patched" << EOF
AIX Platform Override Applied
Date: $(date)
Platform: $(uname -s) $(uname -m)
Node.js: $(node --version)
EOF

echo "SUCCESS: Platform override system installed"
exit 0