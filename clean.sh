#!/bin/bash
# clean-special-chars.sh - Remove special characters from all files

cd ~/utility/vscodium-aix-server

echo "Scanning for special characters..."
echo ""

# Function to clean a file
clean_file() {
    local file="$1"
    local backup="${file}.backup-special-chars"
    
    # Check if file contains special characters
    if grep -P '[^\x00-\x7F]' "$file" > /dev/null 2>&1; then
        echo "Cleaning: $file"
        
        # Create backup
        cp "$file" "$backup"
        
        # Replace common special characters with ASCII equivalents
        sed -i 's/✓/OK/g' "$file"
        sed -i 's/✗/X/g' "$file"
        sed -i 's/❌/ERROR/g' "$file"
        sed -i 's/⚠️/WARNING/g' "$file"
        sed -i 's/⚠/WARNING/g' "$file"
        sed -i 's/🚀/START/g' "$file"
        sed -i 's/🔔/ALERT/g' "$file"
        sed -i 's/ℹ️/INFO/g' "$file"
        sed -i 's/ℹ/INFO/g' "$file"
        sed -i 's/✅/SUCCESS/g' "$file"
        sed -i 's/━/=/g' "$file"
        sed -i 's/│/|/g' "$file"
        sed -i 's/├/+/g' "$file"
        sed -i 's/└/+/g' "$file"
        sed -i 's/─/-/g' "$file"
        sed -i 's/…/.../g' "$file"
        sed -i 's/'/'"'"'/g' "$file"
        sed -i 's/'/'"'"'/g' "$file"
        sed -i 's/"/"/g' "$file"
        sed -i 's/"/"/g' "$file"
        sed -i 's/—/-/g' "$file"
        sed -i 's/–/-/g' "$file"
        
        # Remove any remaining non-ASCII characters (except newlines)
        # Be careful with this - it removes ALL non-ASCII
        # Uncomment if needed:
        # iconv -f utf-8 -t ascii//TRANSLIT "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
        
        echo "  Backed up to: $backup"
    fi
}

# Clean shell scripts
echo "=== Cleaning Shell Scripts ==="
for file in scripts/*.sh scripts/modules/*.sh scripts/utils/*.sh; do
    if [[ -f "$file" ]]; then
        clean_file "$file"
    fi
done

# Clean README
echo ""
echo "=== Cleaning Documentation ==="
if [[ -f "README.md" ]]; then
    clean_file "README.md"
fi

# Clean any other text files
echo ""
echo "=== Cleaning Other Files ==="
for file in *.txt *.md; do
    if [[ -f "$file" ]]; then
        clean_file "$file"
    fi
done

echo ""
echo "=== Verification ==="
echo "Checking for remaining special characters..."

# Find files with non-ASCII characters
grep -r -P '[^\x00-\x7F]' scripts/ README.md 2>/dev/null | head -20

echo ""
echo "Done! Backups created with .backup-special-chars extension"
echo ""
echo "To remove backups after verifying:"
echo "  find ~/utility/vscodium-aix-server -name '*.backup-special-chars' -delete"
