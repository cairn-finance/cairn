## What changed

<!-- One or two sentences. Link the issue this closes, if any. -->

## Checklist

- [ ] `swift test` passes.
- [ ] `swiftlint` reports no new warnings in the files I touched.
- [ ] If I changed `Sources/CairnCore/Models`, I understand the change needs a
      CloudKit schema promotion before it can ship (see
      [`docs/releasing.md`](https://github.com/sehejjain/cairn/blob/main/docs/releasing.md)),
      and `Scripts/schema-hash.sh --check` either passes or the promotion is
      recorded.
- [ ] I did not commit secrets, credentials, or `.env` files.

## Notes for reviewers

<!-- Screenshots, manual-test notes, or anything that still needs verification. -->
