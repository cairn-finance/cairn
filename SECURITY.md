# Security Policy

## Reporting a vulnerability

Please do not open a public issue for security problems. Instead, use GitHub's
private vulnerability reporting on this repository, or email the maintainer.

Include:

- a description of the issue and its impact,
- steps to reproduce,
- affected version or commit.

You can expect an acknowledgement within a few days.

## Scope

In scope:

- Credential handling (Keychain, sync behavior, logging).
- Transport security and URL handling.
- Data isolation between the local store, iCloud, and the SimpleFIN server.
- Injection through server-provided text.

Out of scope:

- Compromise of the SimpleFIN service or your bank.
- A stolen unlocked device (see `docs/threat-model.md`).
- Issues that require a jailbroken device or attacker-controlled hardware.

## Design commitments

- Secrets are stored in the Keychain and never logged.
- All network traffic is HTTPS with default certificate verification.
- Financial fields use CloudKit encrypted fields.
- There is no Cairn-operated server.