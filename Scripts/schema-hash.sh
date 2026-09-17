#!/usr/bin/env bash
#
# Cairn's CloudKit schema change detector.
#
# CloudKit fixes a field's encryption setting the moment the schema is deployed
# to Production: it can never be flipped afterwards, in either direction. So a
# change to Cairn's models must be deployed to Production *before* the release
# that carries it, and `Config/schema-promotions.txt` records that it was.
#
# What is hashed is the schema definition, not the file: the models list, every
# `@Model` class, every stored property (whatever its access modifier, including
# multi-line attribute and relationship declarations), every `#Index`/`#Unique`
# body, and every encryption attribute. Computed properties are excluded, because
# their bodies are rebuilt on every launch and cannot affect what CloudKit sees —
# so tidying a doc comment or rewriting a computed body does not demand a
# deployment, while a type, a name, a default, an index, or an encryption
# attribute does.
#
# Usage:
#   Scripts/schema-hash.sh                       # print the current schema hash
#   Scripts/schema-hash.sh --check               # exit 1 unless it is recorded
#   Scripts/schema-hash.sh --record [note]       # append a promotion line
#   Scripts/schema-hash.sh --extract [path...]   # print what gets hashed
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

# Default file list, sorted explicitly rather than trusting the shell's glob
# order, and with a C locale so the sort does not depend on the environment.
schema_files() {
    find Sources/CairnCore/Models -maxdepth 1 -name '*.swift' -type f | LC_ALL=C sort
}

# Prints one normalized line per schema-relevant declaration.
#
# Deliberately dependency-free and portable: plain POSIX awk, no gawk-isms, so
# the same program runs on macOS and on the Linux CI runner.
schema_declarations() {
    # `-f /dev/stdin` keeps the program out of the file list and out of shell
    # quoting. The program is a here-doc so it stays readable in this file.
    LC_ALL=C awk -f /dev/stdin "$@" <<'AWK'
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function squash(s) { gsub(/[ \t]+/, " ", s); return s }

# Net bracket depth, so a declaration split across lines is joined.
function depth(s,    i, c, d) {
    d = 0
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "(" || c == "[") d++
        else if (c == ")" || c == "]" || c == "") d--
    }
    return d
}

# A line that only closes or separates: finishes whatever is being accumulated.
function closer(s) { return (s ~ /^[}\]\);,]+$/) }

# Only declarations and their fragments are hashed. A line of a computed body
# (`cumulative.last?.x ?? y`) matches nothing here and is dropped.
function relevant(s) {
    return (s ~ /(^| )var / || s ~ /#(Index|Unique)/ || s ~ /@Model/ \
        || s ~ /(^| )class / || s ~ /@Attribute/ || s ~ /@Relationship/ \
        || s ~ /^\[ .*[.]self/)
}

function flush(   s, keep) {
    s = squash(trim(buf))
    buf = ""
    if (s == "") return
    if (!relevant(s)) return
    # A computed property's body is not part of the schema. The models list is a
    # computed property too, but it is exactly what CloudKit turns into record
    # types, so it is kept along with class declarations and index bodies.
    if (index(s, "{") > 0 \
        && s !~ /models: \[any PersistentModel[.]Type\]/ \
        && s !~ /(@Model|class) / \
        && s !~ /#(Index|Unique)/) return
    print s
}

BEGIN { buf = "" }

{
    s = trim($0)
    if (s == "") { flush(); next }
    if (s ~ /^\/\//) { next }            # line and doc comments
    if (s ~ /^\/\*/ || s ~ /^\*/) { next }  # block comments
    if (closer(s)) { buf = (buf == "" ? s : buf " " s); flush(); next }
    buf = (buf == "" ? s : buf " " s)
    if (depth(buf) > 0) next
    last = substr(s, length(s), 1)
    if (last == ":" || last == "=" || last == ",") next
    flush()
}

END { flush() }
AWK
}

schema_hash_for() {
    schema_declarations "$@" | digest
}

schema_hash() {
    schema_hash_for $(schema_files)
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
        echo "::error::Sources/CairnCore/Models changed, but this schema has no recorded Production promotion. Current hash: $current"
        echo ""
        echo "CloudKit fixes a field's encryption setting at deployment, so a changed"
        echo "schema has to be deployed before it ships. To clear this:"
        echo ""
        echo "  1. Create the CloudKit container if it is new, then run a Debug build"
        echo "     with -cairn-initialize-cloudkit-schema, which declares every record"
        echo "     type and field in the Development environment."
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
    --extract)
        shift
        if [ "$#" -eq 0 ]; then
            schema_declarations $(schema_files)
        else
            schema_declarations "$@"
        fi
        ;;
    "")
        echo "$current"
        ;;
    *)
        echo "usage: Scripts/schema-hash.sh [--check | --record [note] | --extract [path...]]" >&2
        exit 2
        ;;
esac
