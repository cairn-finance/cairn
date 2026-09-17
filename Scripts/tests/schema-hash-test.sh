#!/usr/bin/env bash
#
# Fixture test for Scripts/schema-hash.sh.
#
# The hash exists to answer one question: does this change need a CloudKit
# Production deployment before it ships? It has to be sensitive to everything
# CloudKit sees — types, names, defaults, indices, encryption attributes — and
# insensitive to everything it doesn't, including computed-property bodies and
# comments. Getting that wrong in the noisy direction blocks releases for no
# reason; getting it wrong in the quiet direction ships an undeployed schema.
#
# Runs on macOS and Linux, so CI proves the awk program is portable.
#
set -euo pipefail

cd "$(dirname "$0")/../.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if command -v shasum >/dev/null 2>&1; then
    digest() { shasum -a 256 | cut -d' ' -f1; }
else
    digest() { sha256sum | cut -d' ' -f1; }
fi

hash_of() {
    Scripts/schema-hash.sh --extract "$1" | digest
}

write_fixture() {
    cat > "$tmp/Schema.swift" <<'SWIFT'
import Foundation

/// A fixture model file.
enum FixtureSchema: VersionedSchema {
    public static var models: [any PersistentModel.Type] {
        [
            Thing.self,
            Other.self,
        ]
    }

    @Model
    public final class Thing {
        public var id: String = ""
        @Attribute(.allowsCloudEncryption) public var name: String = ""
        private var secretNote: String = ""

        @Relationship(
            deleteRule: .cascade,
            inverse: \Other.thing
        )
        public var others: [Other]?

        // A comment that must not change the hash.
        public var label: String {
            "\(id) \(name)"
        }

        #Index<Thing>(
            [\.id],
            [\.name]
        )
    }

    @Model
    public final class Other {
        public var id: String = ""
        public var thing: Thing?
    }
}
SWIFT
}

failures=0

check() { # check <description> <expected: same|different> <mutator>
    local before after
    write_fixture
    before="$(hash_of "$tmp/Schema.swift")"
    # Start the mutation from a clean base, so each case is independent.
    write_fixture
    "$3"
    after="$(hash_of "$tmp/Schema.swift")"
    local result="different"
    [ "$before" = "$after" ] && result="same"
    if [ "$result" = "$2" ]; then
        echo "ok    $1"
    else
        echo "FAIL  $1 (expected $2, got $result)"
        failures=$((failures + 1))
    fi
}

mutate_nothing() { :; }

mutate_comment() {
    sed -i.bak 's|// A comment that must not change the hash.|// A reworded comment.|' "$tmp/Schema.swift"
    rm -f "$tmp/Schema.swift.bak"
}

mutate_computed_body() {
    sed -i.bak 's|"\\(id) \\(name)"|"\\(name) reordered \\(id)"|' "$tmp/Schema.swift"
    rm -f "$tmp/Schema.swift.bak"
    # Guard against the sed silently doing nothing and the test passing vacuously.
    grep -q "reordered" "$tmp/Schema.swift"
}

mutate_index() {
    sed -i.bak 's|\[\\\.name\]|[\\\.name],\n            [\\.secretNote]|' "$tmp/Schema.swift"
    rm -f "$tmp/Schema.swift.bak"
    grep -q "secretNote\]" "$tmp/Schema.swift"
}

mutate_private_property() {
    sed -i.bak 's|private var secretNote: String = ""|private var secretNote: String = ""\n        private var addedLater: Int = 0|' "$tmp/Schema.swift"
    rm -f "$tmp/Schema.swift.bak"
    grep -q "addedLater" "$tmp/Schema.swift"
}

mutate_encryption() {
    sed -i.bak 's|public var id: String = ""|@Attribute(.allowsCloudEncryption) public var id: String = ""|' "$tmp/Schema.swift"
    rm -f "$tmp/Schema.swift.bak"
}

mutate_models_list() {
    sed -i.bak 's|            Other.self,||' "$tmp/Schema.swift"
    rm -f "$tmp/Schema.swift.bak"
}

check "a comment edit does not change the hash" same mutate_comment
check "a computed-property body edit does not change the hash" same mutate_computed_body
check "an index change changes the hash" different mutate_index
check "a new private stored property changes the hash" different mutate_private_property
check "a new encryption attribute changes the hash" different mutate_encryption
check "removing a model from the models list changes the hash" different mutate_models_list

if [ "$failures" -ne 0 ]; then
    echo ""
    echo "$failures schema-hash fixture(s) failed."
    exit 1
fi

echo ""
echo "schema-hash fixtures passed."
