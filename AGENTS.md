# Cairn repository instructions

- Add user-facing notes for features and fixes under `Unreleased` in
  `CHANGELOG.md`. Keep one `Unreleased` section at the top of the changelog.
- `Scripts/release.sh` moves those notes into the new versioned section and
  leaves an empty `Unreleased` section for future work.
- Run the release script only when the user explicitly requests a release. It
  updates the version, commits, tags, and pushes to the remote.
