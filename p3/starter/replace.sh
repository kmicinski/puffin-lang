#!/bin/bash
# replace.sh — replace all test/*/driver.py with the driver.py in this directory

# Get the absolute path of this script’s directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_FILE="$SCRIPT_DIR/driver.py"

# Check that driver.py exists in the script’s directory
if [[ ! -f "$SOURCE_FILE" ]]; then
    echo "Error: $SOURCE_FILE not found."
    exit 1
fi

# Loop through all driver.py files under test/*/
find "$SCRIPT_DIR/test" -type f -path "*/driver.py" | while read -r TARGET_FILE; do
    echo "Replacing: $TARGET_FILE"
    cp "$SOURCE_FILE" "$TARGET_FILE"
done

echo "All driver.py files replaced successfully."
