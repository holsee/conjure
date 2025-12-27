# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1-alpha] - 2025-12-27

### Changed

- **BREAKING**: Updated YAML frontmatter schema to match [Agent Skills specification](https://agentskills.io/specification)
  - Required fields: `name`, `description`
  - Optional fields: `license`, `compatibility`, `allowed-tools`, `metadata`
- **BREAKING**: Renamed `extra` field to `metadata` in `Conjure.Frontmatter` struct
- **BREAKING**: Renamed `extra` field to `metadata` in `Conjure.Skill` struct
- Updated all SKILL.md files and documentation to use spec-compliant frontmatter format

### Added

- Support for `compatibility` field (environment requirements, max 500 chars)
- Support for `allowed-tools` field (space-delimited pre-approved tools, experimental)
- Support for `metadata` field (additional key-value properties)
- Alpha release notice in README with guidance on version pinning

## [0.1.0-alpha] - 2025-12-27

### Added

- Core skill loading from directories and `.skill` ZIP packages
- YAML frontmatter parsing for skill metadata in `SKILL.md` files
- System prompt generation with XML-structured format
- Tool definitions extraction from skill scripts
- GenServer-based skill registry with process monitoring
- Multiple execution backends:
  - `Conjure.Backend.Local` - Direct local execution (development)
  - `Conjure.Backend.Docker` - Containerized execution (production)
  - `Conjure.Backend.Anthropic` - Anthropic Skills API integration
  - `Conjure.Backend.Native` - Pure Elixir skill execution
- Unified `Conjure.Executor` behaviour for pluggable execution
- Conversation loop management with `Conjure.Conversation`
- Artifact storage backends:
  - `Conjure.Storage.Local` - Local filesystem storage
  - `Conjure.Storage.S3` - S3-compatible storage
  - `Conjure.Storage.Tigris` - Tigris object storage
- Native Elixir skills with `Conjure.NativeSkill` behaviour
- Telemetry integration for observability
- Mix tasks for skill validation
- Comprehensive documentation with tutorials and ADRs
