# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
