# Installing Emerald via Mise

Emerald is release-based: GitHub Releases are the source of truth for distributable binaries, and a dedicated Mise plugin can install the right asset for each platform.

## Recommended flow

1. Tag a release such as `v0.1.0`.
2. Publish binary archives from the GitHub Actions release workflow.
3. Install Emerald through a Mise plugin or a compatible plugin shim.

## Standard Mise usage

Once the release assets are published on GitHub, the expected UX is to point Mise at the GitHub repository directly:

```bash
mise use -g "github:amortimer20/emerald-lang@latest"
```

Or for a specific version:

```bash
mise use -g "github:amortimer20/emerald-lang@v0.1.0"
```

This uses Mise's `github` backend against the repository that holds the release assets. `github:` is the direct install path for a tool whose release artifacts follow the backend's conventions.

## Release asset naming

The release workflow publishes archives with consistent names:

- `emerald-linux-x86_64.tar.gz`
- `emerald-macos-arm64.tar.gz`
- `emerald-windows-x86_64.zip`

The Mise plugin should match the local OS and architecture against these filenames, then unpack the archive into the Mise bin directory.

## Why this approach

This keeps Emerald compatible with the existing Zig toolchain workflow in the repository while giving users a first-class install experience through Mise. It also keeps the project simple: the repo owns binary builds and release packaging, while the plugin is the thin user-facing adapter.
