#!/system/bin/sh
set -eu
feature="$1/feature"
read -r original override < "$feature/hashes.txt"
/system/bin/sh "$feature/cache-test.sh" "$feature" "$original" "$override"
