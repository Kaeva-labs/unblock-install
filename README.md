# unblock-install

Hosting source for **install.kaeva.app** — the UNBLOCK download surface, one page serving three acquisition paths:

1. **Desktop app** (Tauri) — per-OS download buttons resolved live from the desktop release repo via `/api/desktop`.
2. **Web app / PWA** — link to [app.kaeva.app](https://app.kaeva.app) with browser-install guidance.
3. **CLI** — the original one-liner installer for the [UNBLOCK CLI](https://github.com/Kaeva-labs/unblock-install/releases/latest).

## Usage

- **Linux / macOS**

  ```sh
  curl -sSL install.kaeva.app | sh
  ```

- **Windows (PowerShell)**

  ```powershell
  iwr -useb install.kaeva.app | iex
  ```

  PowerShell clients are content-negotiated to `install.ps1` automatically. Explicit form: `iwr -useb install.kaeva.app/install.ps1 | iex`.

## What the installer does

| step | behavior |
|------|----------|
| 1 | Detect OS (`linux` / `darwin` / `windows`) and arch (`x64` / `arm64`). |
| 2 | If `unblock` is already on PATH and its `--version` is ≥ the latest GitHub release, exit `2`. |
| 3 | Download `unblock-<os>-<arch>[.exe]` from the latest release of `Kaeva-labs/unblock-install`. |
| 4 | SHA256-verify against `SHA256SUMS` published alongside the release. |
| 5 | Install:<br>• Linux/macOS → `$HOME/.local/bin/unblock` (chmod +x).<br>• Windows → `$env:LOCALAPPDATA\unblock\unblock.exe`. |
| 6 | **Linux/macOS only:** RUN the installed binary and require **both** `rc=0` **and** non-empty output. If it does not run, fail with a cause-specific error and do **not** touch shell rc files. |
| 7 | Add to PATH (shell rc on Linux/macOS; USER PATH via `[Environment]::SetEnvironmentVariable` on Windows), then print the onboarding hint pointing the user at `unblock login` / `unblock initialize`. |

Exit codes: `0` ok · `1` failure (including *installed but does not execute*) · `2` already installed (skipped).

### Why step 6 executes the binary

A downloaded, sha-verified, `chmod +x`'d file is **not** a working CLI. On Apple
Silicon an **unsigned arm64** Mach-O is SIGKILLed by the kernel before the
program starts, so it returns **rc=137 with zero bytes on stdout and stderr** —
which means a check that only scrapes stdout for a version string sees no error
text and passes it (see [#20](https://github.com/Kaeva-labs/unblock-install/issues/20)).
Hence *both* conditions.

Two silent-death codes are distinguished, because they need opposite fixes:

| exit | signal | cause | fix |
|------|--------|-------|-----|
| `137` | SIGKILL | unsigned arm64 binary | any signature, even ad-hoc `codesign -s - --force` |
| `133` | SIGTRAP | signed **with** hardened runtime, no entitlements → JIT denied | `com.apple.security.cs.allow-jit` (the signature is already fine) |

`install.sh` env knobs: `UNBLOCK_VERSION` · `UNBLOCK_INSTALL_DIR` ·
`UNBLOCK_NO_MODIFY_PATH` · `UNBLOCK_LATEST_URL` · `UNBLOCK_NO_VERIFY` (skip
step 6, warns loudly) · `UNBLOCK_VERIFY_TIMEOUT` (default `20` seconds).

> **Parity gap:** `install.ps1` does not yet run step 6. Windows has no
> equivalent kernel signature requirement, so it is not the same P0 — but the
> "never executes what it installed" gap is the same shape and is still open.

## Repo layout

```
.
├── install.sh                 POSIX bash installer (Linux + macOS)
├── install.ps1                PowerShell 5.1+ installer (Windows)
├── landing.html               Human-facing download page (served to browsers)
├── _redirects                 CF Pages explicit-path routing
├── functions/index.js         CF Pages Function — UA / Accept negotiation for `/`
├── functions/api/desktop.js   CF Pages Function — resolves latest desktop (Tauri) release per-platform
├── tests/
│   ├── test_install_sh.sh     bash integration tests (mock GH release)
│   ├── Test-InstallPs1.ps1    PowerShell integration tests (mock GH release)
│   └── test_desktop_api.mjs   node unit tests for the /api/desktop asset matcher
└── README.md
```

(CI note: this repo's GitHub Actions workflows were removed — CI runs on Fly via `unblock_ci`.)

## Desktop app downloads (`/api/desktop`)

`functions/api/desktop.js` resolves the newest release of the **desktop release repo**
(env var `DESKTOP_REPO` in the Pages project settings; default `Kaeva-labs/unblock`)
and maps Tauri v2 bundle assets to platforms (`windows-x64`, `macos-arm64`, `linux-x64`, …):
NSIS `-setup.exe` > `.msi`; arch `.dmg` > `universal.dmg`; `.AppImage` > `.deb` > `.rpm`.
It tries `releases/latest` first, then falls back to the releases list because
`releases/latest` excludes prereleases — and the beta ships as `prerelease: true`
(`v0.1.0-beta`). Responses are edge-cached 5 minutes. If no usable release exists it
returns `{ "available": false }` and the landing page shows an honest degraded state.

> ⚠️ **Do NOT publish desktop artifacts to this repo's releases.** `install.sh` /
> `install.ps1` resolve `releases/latest` of `Kaeva-labs/unblock-install` for the **CLI**;
> a desktop release becoming "latest" here would break the CLI installer. Desktop
> artifacts belong in the repo `DESKTOP_REPO` points at (public, with Tauri bundle
> assets + `SHA256SUMS`).

## Beta waitlist (`/api/waitlist`)

`functions/api/waitlist.js` accepts `POST {email}` (JSON or form-encoded), drops
honeypot hits quietly, and proxies valid signups to the `WAITLIST_ENDPOINT` env var
(owned by unblock_substrate; proposed contract `POST {email, source, ts}` → 2xx).
Unconfigured → honest `503`; upstream failure → honest `502`; never a fake success.

Deploy checklist for the waitlist path:
1. Set `WAITLIST_ENDPOINT` in the Pages project settings.
2. Add a Cloudflare WAF rate-limit rule on `POST /api/waitlist` (the function itself
   has no per-IP limit — by design, edge rules are the right layer).
3. Upstream store must upsert by email (idempotent) so repeat submissions dedupe.

## Update feed (`/feed/updates.json`) — M2 update channel

Static signed JSON feed (Viraj ruling, PRD-VOICE-PROACTIVE-DESKTOP §4-M2) announcing
shipped features + SOP updates. Consumers: the desktop **What's New** pane (humans),
the substrate SOP-ingest path (org-brain), and the M1 capability provisioner.

- **Schema `unblock-update-feed/v1`**: `{schema, generated_at, items[]}`; each item
  `{id, date, kind: feature|sop|release, title, body, action?{label, target},
  sop?{content, sop_version, tags?}, provision?{manifest_url, min_manifest_version}}`.
  `action.target` is an https URL or a local `app:` route (desktop pane opens https via
  its system-browser opener). `provision` carries ONLY the manifest pointer — the feed is
  the notification, the signed manifest is the authority (unblock_cli M1 interim
  contract). Title = one plain-language sentence, one button (Frank-mode default; maya
  owns copy — every item is a public claim).
- **Transport note for verifiers**: sign/verify is over the origin file's exact bytes;
  HTTP content-encoding (gzip/br) is transparent — verify the DECODED response body,
  which equals the origin bytes. Never re-serialize the JSON before verifying.
- **SOP items** (per SOP-WRITE-CONTRACT **v1.1**, blk_7bc37a74, supersedes blk_69cdf67d):
  the item `id` is the **supersede join key and MUST stay stable across versions** of the
  same SOP — bump `sop.sop_version` (monotonic int) and `date`, never the id. Per-install
  clients (no org-side ingester) write versions append-only via `/v1/remember` with
  `parent_block_id` lineage; newest-per-id wins on read. No `supersedes` field exists —
  the feed cannot reference per-org block ids. Substrate dedup is (author_did,
  content_hash) = AUTHOR-scoped, so clients MUST pre-check by id tag + sop_version
  before writing (contract §v1.1).
- **Hard gate**: `kind=sop` items and `provision` fields MUST NOT ship while the feed is
  unsigned — signature verification is a hard precondition for brain writes and
  provisioning (substrate contract). The unsigned-dev feed may carry only informational
  `feature`/`release` items. Enforced by `tests/test_feed.mjs` (fails if a sop/provision
  item exists without `updates.json.sig` alongside).
- **Signature**: ed25519 detached over the EXACT BYTES of `updates.json`, base64 in
  `updates.json.sig`. Never reformat the file after signing. **The public key is NOT
  served from this origin** — it is pinned in the desktop binary; a same-origin key
  would make the signature theater. Tooling: `node scripts/feed-sign.mjs
  keygen|sign|verify` (keygen output `*.key` is private — never commit).
- **Key custody (RULED 2026-07-21)**: the private key lives in the Supabase **Vault**
  (row `update_feed_signing_key`, same custody class as the other app secrets — never a
  key file in a repo). One-time mint: `scripts/mint_feed_signing_key.mjs` — **Viraj-run,
  human-gated** (`--arm-viraj-run`; dry-runs otherwise; refuses if the row exists;
  read-back sign/verify proves the stored key; prints ONLY the public key, which gets
  pinned in the desktop binary). Publish flow: `scripts/feed-publish-sign.mjs` reads the
  key from the Vault at publish time, signs the exact bytes, self-verifies, writes
  `updates.json.sig`, and prints the corresponding public key for an eyeball match
  against the pinned one. Until the mint runs, `updates.json.sig` is absent and the
  feed is unsigned-dev (informational items only, test-enforced).
- Sanity: `node tests/test_feed.mjs` (schema + sign/verify roundtrip + tamper detection).

## Releasing the CLI binary

The installer expects assets named **`unblock-<os>-<arch>[.exe]`** plus a
**`SHA256SUMS`** file in the same release.

Canonical build+publish machinery lives in `unblock_ci/release-runner/scripts/build-and-release.sh`
(clones the polyrepo siblings, builds the pkg target matrix, generates `SHA256SUMS`, publishes
via `gh`). Releases are cut on an off-Actions runner. They land on **this**
repo (`Kaeva-labs/unblock-install`) — that is what the installer scripts resolve at runtime.

Equivalent manual `gh` flow:

```sh
# 1. Build native binaries (pkg, nexe, deno compile, etc.)
unblock-linux-x64
unblock-linux-arm64
unblock-darwin-x64
unblock-darwin-arm64
unblock-windows-x64.exe
unblock-windows-arm64.exe

# 2. Generate SHA256SUMS
sha256sum unblock-* > SHA256SUMS

# 3. Publish
gh release create v0.1.0 \
  unblock-linux-x64 unblock-linux-arm64 \
  unblock-darwin-x64 unblock-darwin-arm64 \
  unblock-windows-x64.exe unblock-windows-arm64.exe \
  SHA256SUMS \
  --title "v0.1.0" --notes "..."
```

`install.sh` parses `tag_name` from the GitHub releases API with `grep`/`sed`
— no `jq` dependency on the client side.

## TODO(v2): cosign signature verification

For v1 we trust the release artifacts based on:

1. HTTPS transport to `api.github.com` and `objects.githubusercontent.com`.
2. SHA256 checksum of the downloaded binary against a `SHA256SUMS` file in
   the same release.

For v2 we want a full **cosign keyless-sign / verify** chain:

```sh
# Release side (in the CLI release CI):
cosign sign-blob \
  --yes \
  --bundle SHA256SUMS.cosign.bundle \
  SHA256SUMS

# Client side (added to install.sh + install.ps1):
cosign verify-blob \
  --bundle SHA256SUMS.cosign.bundle \
  --certificate-identity "https://github.com/Kaeva-labs/unblock-install/.github/workflows/release.yml@refs/tags/${TAG}" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  SHA256SUMS
```

Until then the installer prints a banner noting that signature verification
is not yet performed.

## Cloudflare Pages binding

This repo is wired to **`install.kaeva.app`** via Cloudflare Pages:

1. Pages → **Create project** → **Connect to Git** → `Kaeva-labs/unblock-install` → `main` branch.
2. Build command: *(none — static)*. Output directory: `/`.
3. **Custom domains** → add `install.kaeva.app` (CNAME to `<project>.pages.dev`, orange-cloud proxied for auto-cert).
4. The Pages Function at `functions/index.js` handles UA-based content negotiation for `/`.

> ⚠️ **The live project is NOT git-connected today — it is deploy-by-hand — and its
> `build_config.destination_dir` is currently `dist`, NOT the `/` this doc specifies (measured
> 2026-08-08).** This repo serves from the ROOT (`install.sh`, `functions/`, `landing.html` are
> all top-level; there is no `dist/`). Manual `wrangler pages deploy .` ignores `destination_dir`
> so it works, but **connecting the existing project to git as-is would build and publish an empty
> `dist/`, taking install.kaeva.app DOWN.** Before you connect: verify with
> `GET /accounts/<acct>/pages/projects/unblock-install` → `build_config.destination_dir`, set it to
> `/` (root) with no build command FIRST, then connect. The `destination_dir` prerequisite is the
> part that bites, not the OAuth step.
>
> Also, deploy-by-hand only: run `wrangler pages deploy .` from **inside** this checkout — never
> `wrangler pages deploy <this-dir>` from another project's directory, which bundles *that*
> project's `functions/` (the static assets upload correctly but every `/api/*` then serves the
> wrong app's routes).

## Local testing

```sh
# bash installer
bash tests/test_install_sh.sh

# PowerShell installer
pwsh -File tests/Test-InstallPs1.ps1

# /api/desktop asset matcher
node tests/test_desktop_api.mjs
```

## License

Apache-2.0. See [`LICENSE`](./LICENSE).
