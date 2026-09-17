#!/usr/bin/env bash
#
# Cairn's CloudKit schema change detector.
#
# CloudKit fixes a field's encryption setting the moment the schema is deployed
# to Production: it can never be flipped afterwards, in either direction. So a
# change to Cairn's models must be deployed to Production *before* the release
# that carries it, and `Config/schema-promotions.txt` records that it was.
#
# The hash covers declarations only, with whitespace collapsed. Comments and
# formatting are ignored, so tidying a doc comment does not demand a deployment;
# anything CloudKit actually sees — a type, a property name, an attribute, a
# default, an index — does.
#
# Usage:
#   Scripts/schema-hash.sh                     # print the current schema hash
#   Scripts/schema-hash.sh --check             # exit 1 unless it is recorded
#   Scripts/schema-hash.sh --record [note]     # append a promotion line
#
# Run `--record` only after the CloudKit Console shows the financial fields as
# encrypted in Development *and* the schema has been deployed to Production.
# See docs/releasing.md.
#
# The note is free text and lands in Config/schema-promotions.txt. Keep bundle
# ids and container names out of it: both stay out of this repo by convention.
#
set -euo pipefail

cd "$(dirname "$0")/.."

record_file="Config/schema-promotions.txt"

if command -v shasum >/dev/null 2>&1; then
    digest() { shasum -a 256 | cut -d' ' -f1; }
else
    digest() { sha256sum | cut -d' ' -f1; }
fi

schema_hash() {
    grep -hE '^[[:space:]]*(@[A-Za-z]+|public var|var |public static var|#Index|public final class)' \
        Sources/CairnCore/Models/*.swift \
        | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' \
        | digest
}

current="$(schema_hash)"

case "${1:-}" in
    --check)
        if [ ! -f "$record_file" ]; then
            echo "::error::$record_file is missing; it records CloudKit schema promotions."
            exit 1
        fi
        if grep -q "$current" "$record_file"; then
            echo "Schema $current has a recorded CloudKit Production promotion."
            exit 0
        fi
        echo "::error::Sources/CairnCore/Models changed, but this schema has no recorded Production promotion."
        echo ""
        echo "CloudKit fixes a field's encryption setting at deployment, so a changed"
        echo "schema has to be deployed before it ships. To clear this:"
        echo ""
        echo "  1. Create the CloudKit container if it is new, then run a Debug build"
        echo "     signed into iCloud so the Development environment picks the schema up."
        echo "  2. In CloudKit Console, confirm every financial field shows as encrypted."
        echo "  3. Deploy Schema Changes to Production."
        echo "  4. Scripts/schema-hash.sh --record \"<note>\"  and commit the result."
        echo ""
        echo "See docs/releasing.md."
        exit 1
        ;;
    --record)
        note="${2:-}"
        printf '%s  %s  %s  %s\n' \
            "$(date -u +%Y-%m-%d)" "$current" "$(git rev-parse --short HEAD)" "$note" \
            >> "$record_file"
        echo "Recorded $current."
        ;;
    "")
        echo "$current"
        ;;
    *)
        echo "usage: Scripts/schema-hash.sh [--check | --record [note]]" >&2
        exit 2
        ;;
esac
