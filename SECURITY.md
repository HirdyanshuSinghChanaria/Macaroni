# Security Policy

## Supported versions

Macaroni is a single-version project: the latest release on `main` is the only
version receiving fixes.

## Reporting a vulnerability

Please report security issues privately rather than opening a public issue.

Use GitHub's [private vulnerability reporting](https://github.com/HirdyanshuSinghChanaria/Macaroni/security/advisories/new)
(Security → Report a vulnerability), which notifies the maintainer directly and
keeps the discussion private until a fix ships.

Expect an initial response within a week. If the report is valid, the fix and a
credit to you (unless you'd rather stay anonymous) will land in the next
release.

## What Macaroni has access to

Worth understanding when assessing a report's severity:

- **Audio recording permission.** Required for per-app volume, because Core
  Audio classifies process taps as recording. Macaroni reads a tapped app's
  audio, multiplies the samples by your chosen volume, and writes them straight
  to the output device. Nothing is stored, buffered to disk, or transmitted.
- **Accessibility permission.** Used only when scroll inversion is enabled, to
  negate scroll-wheel deltas via a `CGEventTap`. Keyboard events are never
  observed.
- **Clipboard contents.** Held in memory only, capped at 200 entries, and
  discarded when the app quits. Nothing is written to disk.
- **File deletion.** The disk cleaner can delete files under `~/Library/Caches`,
  `~/Library/Logs`, the system temp directory, `~/.Trash`, and installer files
  at the top level of `~/Downloads`. It never deletes without an explicit
  selection and a confirmation dialog, and it never touches system locations or
  other apps' sandboxed containers.
- **Network.** Macaroni makes no network connections. The network readout comes
  from kernel byte counters via `sysctl`, which generate no traffic.

## Things that are deliberately not defended against

- A user with admin access to the machine can, of course, do anything Macaroni
  can do.
- Builds distributed outside this repository's Releases are not signed by the
  maintainer and should not be trusted.
