# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow SemVer.

## [Unreleased]

## [0.1.1] - 2026-03-02

### Added
- Ingress-NGINX preflight “gotchas” warnings (non-blocking) surfaced in trigger ConfigMap status and history.
- Realistic ingress-nginx fixture manifests for E2E coverage.
- Documentation note explaining why regex-style paths are intentionally avoided in E2E fixtures.

### Changed
- Helm chart `version` and `appVersion` aligned to `0.1.1`.
- CI Docker publish tags are now derived from `Chart.yaml:version`.
- Helm deployment image tag now defaults to `.Chart.AppVersion` when `image.tag` is empty.
- Default Helm `image.repository` updated to match the CI publish target.
