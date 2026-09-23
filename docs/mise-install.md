# Installing Emerald via Mise

Emerald is release-based: GitHub Releases are the source of truth for distributable
binaries. Mise's `github` backend installs the right asset for the current platform
directly from those releases, so no dedicated Mise plugin is needed.

## Standard Mise usage

```bash
mise use -g "github:amortimer20/emerald-lang@latest"
```

Or for a specific version:

```bash
mise use -g "github:amortimer20/emerald-lang@v0.4.0"
```

`@latest` resolves through GitHub's release metadata; if it ever misbehaves (for example,
reporting no matching version), pin an explicit tag instead.

This uses Mise's `github` backend against the repository that holds the release assets:
it matches the local OS and architecture against the release filenames below, downloads
the matching archive, and unpacks it into the Mise install directory. No `.mise-plugin/`
directory or custom plugin is required.

## Release asset naming

The release workflow publishes archives with consistent names, plus a `SHA256SUMS` file:

- `emerald-linux-x86_64.tar.gz`
- `emerald-macos-arm64.tar.gz`
- `emerald-windows-x86_64.zip`

## Why this approach

This keeps Emerald compatible with the existing Zig toolchain workflow in the repository
while giving users a first-class install experience through Mise, without maintaining a
separate plugin: the repo owns binary builds and release packaging, and Mise's built-in
GitHub backend does the rest.
