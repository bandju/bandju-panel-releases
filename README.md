# Bandju Panel Releases

This repository contains public release payloads for **Bandju Panel**.

It is intentionally limited to release-facing files:

- desktop installers and archives published on GitHub Releases;
- `latest.json` used by the launcher update flow;
- public production `install.sh` for VPS installs and updates;
- release notes and public notices.

This repository does **not** contain the private source code of Bandju Panel.

## Main links

- Website: [bandju.app](https://bandju.app/)
- Download page: [bandju.app/download/](https://bandju.app/download/)
- Stable manifest: [latest.json](https://raw.githubusercontent.com/bandju/bandju-panel-releases/main/latest.json)
- Public installer: [install.sh](https://raw.githubusercontent.com/bandju/bandju-panel-releases/main/install.sh)

## Stable release contract

The launcher and production panel update flow use:

- a stable release manifest (`latest.json`);
- a published GHCR image for panel updates;
- platform-specific launcher download URLs from GitHub Releases.

## Reporting issues

Use this repository for public release issues such as:

- broken download links;
- corrupted release assets;
- incorrect `latest.json` payload;
- public installer problems.

For product questions and release context, start at [bandju.app](https://bandju.app/).
