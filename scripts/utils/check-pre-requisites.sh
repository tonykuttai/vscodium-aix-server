#!/usr/bin/env bash
# check-pre-requisites-safe.sh - Safe version that avoids npm --version

set +e
set +u

echo "=== AIX Prerequisites Check ==="
echo ""

echo "System Information:"
echo "  OS: $(uname -s)"
echo "  Version: $(uname -v).$(uname -r)"
echo "  Architecture: $(uname -m)"
echo ""

# Function to safely check a command
check_cmd() {
    CMD="$1"
    echo -n "  $CMD: "
    
    if which "$CMD" >/dev/null 2>&1; then
        echo "FOUND at $(which "$CMD")"
        return 0
    else
        echo "NOT FOUND"
        return 1
    fi
}

echo "Required Tools:"
MISSING_COUNT=0

check_cmd git || MISSING_COUNT=$((MISSING_COUNT + 1))
check_cmd node || MISSING_COUNT=$((MISSING_COUNT + 1))
check_cmd npm || MISSING_COUNT=$((MISSING_COUNT + 1))
check_cmd gcc || MISSING_COUNT=$((MISSING_COUNT + 1))
check_cmd g++ || MISSING_COUNT=$((MISSING_COUNT + 1))
check_cmd make || MISSING_COUNT=$((MISSING_COUNT + 1))
check_cmd cargo || MISSING_COUNT=$((MISSING_COUNT + 1))

echo ""
echo "Optional Tools:"
check_cmd wget
check_cmd curl

echo ""
echo "Tool Versions:"

# Node.js version (safe)
if which node >/dev/null 2>&1; then
    NODE_VER=$(node --version 2>/dev/null)
    echo "  Node.js: $NODE_VER"
else
    echo "  Node.js: NOT AVAILABLE"
fi

# npm - DO NOT CHECK VERSION, just check it exists
if which npm >/dev/null 2>&1; then
    echo "  npm: FOUND (version check skipped - known to crash on AIX)"
    echo "       Location: $(which npm)"
else
    echo "  npm: NOT FOUND"
fi

# gcc version
if which gcc >/dev/null 2>&1; then
    GCC_VER=$(gcc --version 2>/dev/null | head -1)
    echo "  gcc: $GCC_VER"
fi

# g++ version
if which g++ >/dev/null 2>&1; then
    GPP_VER=$(g++ --version 2>/dev/null | head -1)
    echo "  g++: $GPP_VER"
fi

# Cargo version
if which cargo >/dev/null 2>&1; then
    CARGO_VER=$(cargo --version 2>/dev/null)
    echo "  Cargo: $CARGO_VER"
fi

echo ""
echo "Node.js Details:"
node -p "'  Platform: ' + process.platform" 2>/dev/null
node -p "'  Architecture: ' + process.arch" 2>/dev/null
node -p "'  Node: ' + process.version" 2>/dev/null

echo ""
if [ $MISSING_COUNT -eq 0 ]; then
    echo "OK All required tools found!"
    echo ""
    echo "WARNING: npm --version crashes on this system"
    echo "         This is a known AIX issue but npm install should still work"
else
    echo "X Missing $MISSING_COUNT required tool(s)"
    echo ""
    echo "Install missing tools:"
    echo "  yum install git gcc gcc-c++ make wget curl"
    echo ""
    echo "For Rust/Cargo:"
    echo "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    exit 1
fi