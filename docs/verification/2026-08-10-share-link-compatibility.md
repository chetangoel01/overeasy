# Share-link compatibility

## Purpose and user-visible behavior

Sharing a recipe video to Overeasy now works when the source puts its URL in
the share item's attributed text instead of a URL or plain-text attachment.
The backend also accepts Instagram's `/share/reel/` URL shape and TikTok's
`/t/`, `vm.tiktok.com`, and `vt.tiktok.com` redirect forms, then stores the
same stable canonical source identity as their direct-link equivalents.

Malformed links, non-HTTP(S) links, and unsupported hosts remain rejected.

## Decisions and affected components

- `LadleShare/ShareURLExtractor.swift` checks each extension item's attributed
  text before its attachments. Existing URL and plain-text handling is
  unchanged.
- `Backend/ladle/imports/source_identity.py` normalizes Instagram's extra
  `/share` path component and sends current TikTok short links through the
  existing DNS-pinned redirect resolver.
- `Backend/ladle/infrastructure/dns.py` explicitly allows `vt.tiktok.com`
  while retaining per-hop DNS validation and IP pinning. No TikTok wildcard
  was added.
- No new dependency, URL abstraction, or client-side platform parser was
  added. The backend remains the source of truth for social URL identity.

## Verification

- The new Share Extension regression first failed with no extracted URL, then
  passed with the attributed-text fallback.
- The new Instagram and TikTok parser regressions first failed as invalid URL
  shapes, then passed after normalization and safe redirect routing.
- The `vt.tiktok.com` parser and pinned-resolver regressions first failed as
  unsupported, then passed after adding the exact short-link host.
- The reported `https://vt.tiktok.com/ZS4NEvuUH/` URL resolved live to TikTok
  video `7656390702540115203` and canonicalized successfully.
- Existing unsupported-scheme, missing-URL, direct URL, plain-text, social
  identity, and unsafe-host cases continue to pass.
- The complete Ladle test target passed on the iPhone 17 simulator. A Release
  simulator build passed and contains the embedded `LadleShare.appex`.
- The current backend suite passed: 510 passed and 5 skipped. Ruff formatting,
  Ruff lint, and strict mypy also passed.

## `vt.tiktok.com` device rollout

- The deployed VPS was still on preserved revision `99624ee`, so the hotfix
  release was built from that exact revision plus the current-share-link and
  `vt.tiktok.com` commits. All 780 tests passed with 5 skips before rollout.
- VPS revision `d560093` activated successfully after archive validation,
  migration, API, edge, worker, and Beat health gates. The previous revision
  remains available for rollback.
- The checked-in Release hostname, `api.ladle.app`, is parked behind
  `ns1.dan.com` and `ns2.dan.com` and fails TLS SNI. The Personal Team device
  build therefore uses the VPS's existing TLS hostname,
  `https://vps-8b0be574.vps.ovh.us`, plus its guarded tunnel key. The key was
  injected only at build time and matched without being printed.
- The replacement signed build installed and launched on the paired iPhone 17
  Pro. It refreshed the existing session, synced successfully, and submitted
  both reported `vt.tiktok.com` links with `202 Accepted`.
- `ZS4NEvuUH` canonicalized to TikTok video `7656390702540115203`, and
  `ZS4NEwJg6` canonicalized to video `7667383250049862925`. Both completed as
  `needsReview` with no failure reason, and both appear that way in the device
  Inbox.
