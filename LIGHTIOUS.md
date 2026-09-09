# Lightious server architecture

Lightious is a focused Light Phone III video and audio experience built on an
Invidious server fork. Invidious remains responsible for account signup,
signin, subscriptions, search, and YouTube extraction. The Lightious additions
are deliberately isolated so the fork can continue to merge upstream changes.

The browser is a control plane. It can search, curate, configure, and send
items to paired phones, but it never embeds or plays media. Playback happens
only in the Kotlin Lightious client.

The Lightious companion control plane and Invidious Companion are separate
components. The former pairs phones and curates their libraries; the latter is
the private YouTube-facing service that resolves playable streams and PO
tokens. Development Compose requires two independent secrets and fails closed
when either is missing:

- `INVIDIOUS_COMPANION_KEY` is the same dedicated, exactly 16-character
  alphanumeric key supplied to Invidious and Invidious Companion.
- `LIGHTIOUS_HMAC_KEY` is a strong random key used by Invidious for signed
  sessions, CSRF tokens, pairing state, and Lightious media capabilities.

Generate local-only values in the ignored `.env` file before starting Compose:

```sh
umask 077
printf 'INVIDIOUS_COMPANION_KEY=%s\nLIGHTIOUS_HMAC_KEY=%s\n' \
  "$(openssl rand -hex 8)" "$(openssl rand -hex 32)" > .env
```

Do not commit or reuse those values in another environment. Development
Compose defaults both Invidious and Companion to the `1.1.1.1` resolver because
both make YouTube requests and the current tailnet DNS policy blocks
`www.youtube.com`; set `INVIDIOUS_COMPANION_DNS` to override that
development-only choice.

The companion has two primary destinations. `/lightious` is Home and contains
phone-wide mode and pairing settings. `/lightious/library` is the canonical
library editor: it searches without playback and manages selected videos,
whole-channel access, playback policy, and links to Lightious playlists. The
legacy `/lightious/search` URL redirects to the library and preserves its query
string. Playlists contain videos, never channel permissions, and may hold a
video without putting it in the phone's main Videos list. Playlist and channel
detail pages provide scoped search and selection without exposing a web player.

## Product modes

New profiles start in **Focused** mode. Existing profiles keep their chosen
mode unless the user changes it from the companion website.

- **Explore** preserves the current Lightious experience: search, account feed,
  local histories, and explicitly enabled pages.
- **Focused** exposes only companion-managed entries. Search, Popular, account
  feed, pasted links, and reopening unauthorized entries are denied by the
  server rather than merely hidden by the client.

Lightious has a hard no-Shorts rule in both modes. Shorts are removed from
companion and phone search, channel views, feeds, playlists, libraries, and
playable device API results. Explicit `/shorts/` links are rejected, and a
video positively identified as a Short during metadata or playback resolution
is quarantined instead of returned. Sync may include its ID only in the
non-display `blockedVideoIds` purge list so a phone can delete stale local
history, cache, or downloads.

Every focused video has one of two playback policies:

- `listen_only`: the client may resolve and play audio, but must not construct
  a video playback source.
- `watch_and_listen`: the client may offer both actions.

An explicitly selected video grants access only to that video. An explicitly
selected channel grants access to that channel's paginated uploads, subject to
its default playback policy; an exact-video policy overrides the channel
default. The client verifies each video's canonical channel ID before exposing
playback. Adding an individual video never creates channel access or makes its
author appear in the Channels list.

Lightious playlists are private companion collections of videos. Playlist-only
membership grants that exact video to the phone while keeping it out of the
main Videos list; adding the same video to the library later only changes its
visibility. Removing a visible library video preserves any playlist
memberships, and removing its last playlist membership cleans up the hidden
record. Videos, explicit channels, and playlists are three independent
organizations.

## Authentication boundary

The managed service uses the existing Invidious account system. Browser routes
under `/lightious` use the normal Invidious SID cookie and CSRF protection. The
fork does not create another password, recovery, or human account system.

When Lightious is enabled, every local Invidious login POST uses the Lightious
origin check and bounded in-process attempt limits, regardless of its return
page or the lockdown setting. After same-origin validation, IP and global
capacity is reserved before a POST does challenge or password work, so
successful registrations are bounded; the account-specific bucket records only
a human-verified credential failure.
Set `lightious.public_url` in every non-local deployment so browser login can
require its exact origin. Leaving that URL empty permits the compatibility path
only when the request Host is `localhost`, `127.0.0.1`, or `::1`.

Public deployments must configure Cloudflare Turnstile or leave Invidious's
built-in CAPTCHA enabled. `captcha_enabled: false` without Turnstile is a
localhost-only development mode, not a supported public configuration.

The phone never receives the Invidious SID, password, or API token. It receives
an independently revocable Lightious device credential that identifies one
device associated with the authenticated Invidious user.

Custom upstream Invidious instances are a separate provider adapter. They must
not be used as identity for the managed service, and callback-provided usernames
must not be trusted as authenticated identity.

## Pairing

Pairing follows the constrained-device shape of OAuth device authorization,
without making the Lightious credential an OAuth token:

1. The phone generates a 256-bit device credential and sends only its SHA-256
   hash when creating a pairing request.
2. The server returns a high-entropy polling secret and a short, unambiguous,
   12-character user code with a ten-minute expiry.
3. The phone displays the code and the `/lightious/pair` address.
4. The signed-in user enters the code in the companion page and approves the
   named device.
5. The phone polls with the pairing secret, displays the approved account, and
   confirms the association.
6. The server atomically creates the device using the previously supplied
   credential hash. The plaintext device credential never crosses the network.

Pairing codes are single-use, short-lived, and stored only as keyed hashes.
Device credentials are random opaque bearer tokens stored only as hashes and
can be revoked per device from the companion page. Production deployments must
also rate-limit pairing creation and code-preview requests at the trusted
reverse proxy. The application applies bounded in-process pairing limits as a
final line of defense; a forwarded client-address header is used only when the
operator explicitly configures one that a trusted proxy always overwrites.

## Current device API

The first vertical slice is revisioned and intentionally small:

- `POST /api/lightious/v1/pairings` accepts a phone-generated device-credential
  digest and returns a pairing ID, polling secret, user code, verification URL,
  and expiry.
- `GET /api/lightious/v1/pairings/:id` uses the polling secret to report
  `pending`, `claimed`, `consumed`, or `expired` without exposing account
  credentials.
- `POST /api/lightious/v1/pairings/:id/activate` atomically installs the
  pre-committed device digest after browser approval and is safe to retry after
  a lost response.
- `GET /api/lightious/v1/sync` accepts only the opaque Lightious device bearer
  and returns the mode, profile revision, masked account label, explicit video
  policies, whole-channel permissions, and Lightious playlist membership.
  Top-level `items` contains only the main Videos library; each playlist embeds
  all of its items, including playlist-only videos. `blockedVideoIds` is a
  non-display list of quarantined Shorts that clients must purge locally.
- `GET /api/lightious/v1/search`, `/popular`, and `/feed` are device-gated and
  available only in Explore mode. The feed is loaded from the Invidious account
  associated during pairing; the phone never needs a second API token.
- `GET /api/lightious/v1/channels/:ucid/videos` is device-gated. Focused mode
  permits it only for an explicitly selected whole channel. Each page combines
  up to 30 newest entries from each of the channel's uploads and livestream
  tabs (60 entries maximum), removes Shorts and duplicate video IDs, and orders
  the result newest-first. Live and upcoming metadata wins when an entry
  appears in both tabs. Pagination values carry both tab positions in an opaque,
  server-signed continuation bound to that device and channel, so a raw
  continuation from another channel cannot bypass the path policy. The normal
  `hl` query parameter controls localized fields such as `publishedText`.
- `GET /api/lightious/v1/channels/:ucid/search` is also device-gated and, in
  Focused mode, is limited to explicitly allowed whole channels. It accepts a
  bounded query and page number, searches the channel's full catalog, removes
  Shorts, blocked video IDs, and wrong-channel results, and returns at most 50
  pages without exposing an upstream continuation token.
- `GET /api/lightious/v1/videos/:id` is device-gated and returns playback
  metadata only when Focused policy permits that exact video or its whole
  channel. An exact-video policy overrides the channel default.
- `GET /api/lightious/v1/history` and
  `POST /api/lightious/v1/history/:id` use the account associated with the
  paired device, without exposing an Invidious SID or API token. Focused mode
  does not expose the account-wide history list and records a watched video
  only after rechecking that the exact video or its channel is still allowed.
- `GET /api/lightious/v1/media` accepts only a short-lived signed media
  capability minted by the metadata endpoint. The capability is scoped to one
  device, video, canonical channel, stream type, source, and expiry. Each range
  request rechecks device revocation and current Focused policy. This URL-based
  capability is required because detached LightAudio playback cannot attach an
  authorization header; the long-lived device bearer is never placed in a URL.

All device responses use `Cache-Control: no-store`. Browser mutations use the
normal Invidious SID plus a signed CSRF scope; the device API never accepts an
Invidious SID or API token as a Lightious credential. Lightious API and media
responses do not opt into wildcard CORS.

## Public-instance lockdown

When Lightious is enabled, `lightious.lockdown` defaults to `true`. The
application then fails closed before normal Invidious routing: generic browser,
watch, embed, search, manifest, `/videoplayback`, and `/api/v1/*` endpoints are
hidden, including authenticated Invidious token APIs. The narrow public
allowlist contains the exact companion and login routes, pairing bootstrap,
required static and thumbnail assets, and `/api/v1/stats` for health checks.
All other Lightious device routes require an active device bearer tied through
its profile to an existing Invidious user. The media route requires its signed
capability and rechecks that same association.

Keep equivalent reverse-proxy restrictions and rate limits as defense in
depth; they are no longer the only barrier preventing direct generic
Invidious-route use. Set `lightious.lockdown: false` only for an intentional
combined Lightious and ordinary Invidious deployment.

## Fork surface

Keep additions in these namespaces and tables:

- Browser Home and phone settings: `/lightious`
- Canonical focused-library editor: `/lightious/library`
- Private video-playlist index and editors: `/lightious/playlists` and
  `/lightious/playlists/:id`
- Companion-only channel browser: `/lightious/channels/:ucid`
- Compatibility search redirect: `/lightious/search`
- Device API: `/api/lightious/v1/*`
- Crystal modules: `Invidious::Lightious::*`
- Database objects: `lightious_*`

Do not modify Invidious's YouTube extraction or playback-selection internals
for companion behavior. A single early lockdown handler owns the public-route
boundary; the Lightious API delegates extraction only after device and mode
authorization. The production reverse proxy should mirror this allowlist.

## Provider model

The first provider is the managed Invidious instance in this fork. A later
custom provider may point at another HTTPS Invidious instance, but it requires
strict outbound-address validation, DNS rebinding defenses, timeouts, response
limits, and an explicit policy for private-network instances in self-hosted
deployments.

Media metadata never returns a generic local proxy URL or the long-lived device
bearer. Progressive audio, video-only, and muxed sources are wrapped in signed
Lightious capability URLs and proxied by the managed instance. HLS, DASH,
livestream, captions, and storyboard proxy playback are intentionally omitted
from this secured first slice; the client must treat an empty compatible-format
list as unsupported and may refetch metadata after a source expires.

## Initial delivery slices

1. Pairing tables, device credential authentication, companion pairing page,
   and device pairing API. **Implemented in the first vertical slice.**
2. Companion mode setting plus revisioned device sync. **Implemented.**
3. Explicit-video library with `listen_only` and `watch_and_listen` policy.
   **Implemented and enforced in both server and Kotlin client.**
4. Companion-only video/channel search, bulk playback policy, independent
   playlist destinations, playlist search, and channel browsing across uploads,
   livestreams, and channel-local search. Shorts are explicitly excluded.
   **Implemented; the companion never links to a player.**
5. Focused Videos, Channels, and Playlists phone views with compact policy
   filters, unified local library search, full-catalog channel search,
   player-style audio, native-aspect video, fullscreen playback, and paginated
   whole-channel uploads and streams. Shorts are explicitly excluded.
   **Implemented in the Kotlin client and paired server API.**
6. Optional custom-instance provider.

The Kotlin client remains a clean Light SDK application. This server-side fork
does not change that client into an Invidious, Clipious, or Materialious wrapper.
