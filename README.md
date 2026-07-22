# unblock-install

Hosting source for **install.kaeva.app** — the UNBLOCK download surface, one page serving three acquisition paths:

1. **Desktop app** (Tauri) — per-OS download buttons resolved live from the desktop release repo via `/api/desktop`.
2. **Web app / PWA** — link to [app.kaeva.app](https://app.kaeva.app) with browser-install guidance.
3. **CLI** — the original one-liner installer for the [UNBLOCK CLI](https://github.com/Viraj0518/unblock-install/releases/latest).

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
| 3 | Download `unblock-<os>-<arch>[.exe]` from the latest release of `Viraj0518/unblock-install`. |
| 4 | SHA256-verify against `SHA256SUMS` published alongside the release. |
| 5 | Install:<br>• Linux/macOS → `$HOME/.local/bin/unblock` (chmod +x; prepended to PATH via shell rc).<br>• Windows → `$env:LOCALAPPDATA\unblock\unblock.exe` (added to USER PATH via `[Environment]::SetEnvironmentVariable`). |
| 6 | Print onboarding hint pointing the user at `unblock login` / `unblock initialize`. |

Exit codes: `0` ok · `1` failure · `2` already installed (skipped).

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

`functions/api/desktop.js` resolves `releases/latest` of the **desktop release repo**
(env var `DESKTOP_REPO` in the Pages project settings; default `Viraj0518/unblock_desktop`)
and maps Tauri v2 bundle assets to platforms (`windows-x64`, `macos-arm64`, `linux-x64`, …):
NSIS `-setup.exe` > `.msi`; arch `.dmg` > `universal.dmg`; `.AppImage` > `.deb` > `.rpm`.
Responses are edge-cached 5 minutes. While no public desktop release exists it returns
`{ "available": false }` and the landing page shows an honest "in final assembly" state —
the page lights up automatically the moment a public release with bundle assets is published.

> ⚠️ **Do NOT publish desktop artifacts to this repo's releases.** `install.sh` /
> `install.ps1` resolve `releases/latest` of `Viraj0518/unblock-install` for the **CLI**;
> a desktop release becoming "latest" here would break the CLI installer. Desktop
> artifacts belong in the repo `DESKTOP_REPO` points at (public, with Tauri bundle
> assets + `SHA256SUMS`).

## Releasing the CLI binary

The installer expects assets named **`unblock-<os>-<arch>[.exe]`** plus a
**`SHA256SUMS`** file in the same release.

Canonical build+publish machinery lives in `unblock_ci/release-runner/scripts/build-and-release.sh`
(clones the polyrepo siblings, builds the pkg target matrix, generates `SHA256SUMS`, publishes
via `gh`). GitHub Actions is billing-locked, so releases are cut off-Actions on a Fly runner
(v0.1.6 was cut by the patched variant in `unblock_cli.wt-v016/`). Releases land on **this**
repo (`Viraj0518/unblock-install`) — that is what the installer scripts resolve at runtime.

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
  --certificate-identity "https://github.com/Viraj0518/unblock-install/.github/workflows/release.yml@refs/tags/${TAG}" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  SHA256SUMS
```

Until then the installer prints a banner noting that signature verification
is not yet performed.

## Cloudflare Pages binding

This repo is wired to **`install.kaeva.app`** via Cloudflare Pages:

1. Pages → **Create project** → **Connect to Git** → `Viraj0518/unblock-install` → `main` branch.
2. Build command: *(none — static)*. Output directory: `/`.
3. **Custom domains** → add `install.kaeva.app` (CNAME to `<project>.pages.dev`, orange-cloud proxied for auto-cert).
4. The Pages Function at `functions/index.js` handles UA-based content negotiation for `/`.
5. (Optional, post-YC) Add `install.unblock.app` as a transitional-alias custom domain so the legacy URL keeps resolving during rebrand.

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
