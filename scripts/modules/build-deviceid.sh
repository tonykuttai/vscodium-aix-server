#!/bin/bash
# modules/build-deviceid.sh
# Patch @vscode/deviceid for AIX platform support

set -e

BUILDDIR="$1"
SERVER_DIR="$2"

if [[ -z "$SERVER_DIR" ]]; then
    echo "Usage: $0 <build_directory> <server_directory>"
    exit 1
fi

MODULE_NAME="@vscode/deviceid"
MODULE_PATH="$SERVER_DIR/node_modules/@vscode/deviceid"

echo "Patching $MODULE_NAME for AIX..."
echo "Server directory: $SERVER_DIR"
echo "Module path: $MODULE_PATH"

# Check if module exists
if [[ ! -d "$MODULE_PATH" ]]; then
    echo "ERROR: Module not found at $MODULE_PATH"
    exit 1
fi

# Check if already patched
if [[ -f "$MODULE_PATH/.aix-patched" ]]; then
    echo "$MODULE_NAME already patched"
    exit 0
fi

# Backup original
echo "Creating backup..."
cp -r "$MODULE_PATH" "$MODULE_PATH.backup"

# Patch index.js
INDEX_FILE="$MODULE_PATH/dist/index.js"
if [[ -f "$INDEX_FILE" ]]; then
    echo "Patching index.js..."
    cp "$INDEX_FILE" "$INDEX_FILE.backup"
    
    sed -i 's/process\.platform !== "linux"/process.platform !== "linux" \&\& process.platform !== "aix"/g' "$INDEX_FILE"
    
    if grep -q 'process.platform !== "aix"' "$INDEX_FILE"; then
        echo "OK index.js patched successfully"
    else
        echo "ERROR: index.js patch verification failed"
        exit 1
    fi
fi

# Patch storage.js
STORAGE_FILE="$MODULE_PATH/dist/storage.js"
if [[ -f "$STORAGE_FILE" ]]; then
    echo "Patching storage.js..."
    cp "$STORAGE_FILE" "$STORAGE_FILE.backup"
    
    sed -i 's/process\.platform === "linux"/process.platform === "linux" || process.platform === "aix"/g' "$STORAGE_FILE"
    
    if grep -q 'process.platform === "aix"' "$STORAGE_FILE"; then
        echo "OK storage.js patched successfully"
    else
        echo "ERROR: storage.js patch verification failed"
        exit 1
    fi
fi

# Mark as patched
cat > "$MODULE_PATH/.aix-patched" << EOF
AIX Patch Applied
Date: $(date)
Module: $MODULE_NAME
Platform: $(uname -s) $(uname -m)
EOF

echo "SUCCESS: $MODULE_NAME patched for AIX"
exit 0