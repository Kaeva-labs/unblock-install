# unblock-install

Hosting source for **install.kaeva.app** — the one-liner installer for the [UNBLOCK CLI](https://github.com/Viraj0518/unblock_cli).

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
| 3 | Download `unblock-<os>-<arch>[.exe]` from the latest release of **this repo** (`Viraj0518/unblock-install` — `unblock_cli` went private; repointed in #5). |
| 4 | SHA256-verify against `SHA256SUMS` published alongside the release. |
| 5 | Install:<br>• Linux/macOS → `$HOME/.local/bin/unblock` (chmod +x; prepended to PATH via shell rc).<br>• Windows → `$env:LOCALAPPDATA\unblock\unblock.exe` (added to USER PATH via `[Environment]::SetEnvironmentVariable`). |
| 6 | Print onboarding hint pointing the user at `unblock spawn` / `unblock login`. |

Exit codes: `0` ok · `1` failure · `2` already installed (skipped).

## Repo layout

```
.
├── install.sh                 POSIX bash installer (Linux + macOS)
├── install.ps1                PowerShell 5.1+ installer (Windows)
├── landing.html               Human-facing landing page (served to browsers; not index.html — avoids CF Pages' /index.html → / canonicalization loop)
├── _redirects                 CF Pages explicit-path routing
├── functions/index.js         CF Pages Function — UA / Accept negotiation for `/`
├── tests/
│   ├── test_install_sh.sh     bash integration tests (mock GH release)
│   └── Test-InstallPs1.ps1    PowerShell integration tests (mock GH release)
├── .github/workflows/test.yml shellcheck + PSScriptAnalyzer + integration tests
└── README.md
```

## Releasing the CLI binary

The installer expects assets named **`unblock-<os>-<arch>[.exe]`** plus a
**`SHA256SUMS`** file in the same release.

Canonical build+publish machinery: `unblock_ci/release-runner/scripts/build-and-release.sh`
(clones the polyrepo siblings, bundles, builds the pkg target matrix, smoke-gates, generates
`SHA256SUMS`, and publishes). Releases land on **this repo** (`Viraj0518/unblock-install`),
which is what the installer scripts resolve at runtime via `releases/latest`.

Equivalent manual `gh` flow:

```sh
# 1. Build native binaries (@yao-pkg/pkg via unblock_cli's "pkg" config)
unblock-linux-x64
unblock-linux-arm64
unblock-darwin-x64
unblock-darwin-arm64
unblock-windows-x64.exe
unblock-windows-arm64.exe

# 2. Generate SHA256SUMS (sorted, deterministic)
sha256sum unblock-* | sort > SHA256SUMS

# 3. Publish to THIS repo
gh release create v0.1.0 \
  unblock-linux-x64 unblock-linux-arm64 \
  unblock-darwin-x64 unblock-darwin-arm64 \
  unblock-windows-x64.exe unblock-windows-arm64.exe \
  SHA256SUMS \
  --repo Viraj0518/unblock-install \
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
# Release side (in unblock_cli CI):
cosign sign-blob \
  --yes \
  --bundle SHA256SUMS.cosign.bundle \
  SHA256SUMS

# Client side (added to install.sh + install.ps1):
cosign verify-blob \
  --bundle SHA256SUMS.cosign.bundle \
  --certificate-identity "https://github.com/Viraj0518/unblock_cli/.github/workflows/release.yml@refs/tags/${TAG}" \
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
```

## License

Apache-2.0. See `LICENSE` in [`Viraj0518/unblock_cli`](https://github.com/Viraj0518/unblock_cli).
