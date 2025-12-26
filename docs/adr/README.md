# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for Conjure.

ADRs document significant architectural decisions made during the development of this project, providing context for future contributors and maintainers.

## Index

| ID | Title | Status |
|----|-------|--------|
| [ADR-0001](0001-adr-format.md) | Use ADR format for architectural decisions | Accepted |
| [ADR-0002](0002-pluggable-executor-architecture.md) | Pluggable executor architecture via behaviours | Accepted |
| [ADR-0003](0003-zip-format-for-skill-packages.md) | ZIP format for .skill packages | Accepted |
| [ADR-0004](0004-api-client-agnostic-design.md) | API-client agnostic design | Accepted |
| [ADR-0005](0005-progressive-disclosure.md) | Progressive disclosure for token efficiency | Accepted |
| [ADR-0006](0006-xml-system-prompt-format.md) | XML format for system prompt fragments | Accepted |
| [ADR-0007](0007-yaml-frontmatter.md) | YAML frontmatter in SKILL.md | Accepted |
| [ADR-0008](0008-genserver-registry.md) | GenServer-based skill registry | Accepted |
| [ADR-0009](0009-local-executor-no-sandbox.md) | Local executor without sandboxing | Accepted |
| [ADR-0010](0010-docker-production-executor.md) | Docker as recommended production executor | Accepted |
| [ADR-0011](0011-anthropic-executor.md) | Anthropic Skills API Integration | Proposed |
| [ADR-0012](0012-mix-tasks.md) | Mix tasks for developer experience | Proposed |
| [ADR-0013](0013-docker-infrastructure.md) | Docker infrastructure and image distribution | Proposed |
| [ADR-0014](0014-security-module.md) | Centralized security module | Proposed |
| [ADR-0015](0015-configuration-driven-loading.md) | Configuration-driven skill loading | Proposed |
| [ADR-0016](0016-test-strategy-external-deps.md) | Test strategy for external dependencies | Proposed |
| [ADR-0017](0017-skill-caching-hot-reload.md) | Skill caching and hot-reload | Proposed |
| [ADR-0018](0018-artifact-references.md) | Artifact References | Proposed |
| [ADR-0019](0019-unified-execution-model.md) | Unified Execution Model | Proposed |
| [ADR-0020](0020-backend-behaviour.md) | Backend Behaviour Architecture | Accepted |
| [ADR-0021](0021-hybrid-multi-backend-sessions.md) | Hybrid Multi-Backend Sessions | Proposed |
| [ADR-0022](0022-storage-strategy.md) | Pluggable Storage Strategy | Proposed |

## ADR Format

Each ADR follows this structure:

```markdown
# ADR-NNNN: Title

## Status
Proposed | Accepted | Deprecated | Superseded by [ADR-NNNN](link)

## Context
What is the issue that we're seeing that is motivating this decision?

## Decision
What is the change that we're proposing and/or doing?

## Consequences
What becomes easier or more difficult because of this change?
```

## Creating New ADRs

1. Copy the template from `0000-template.md`
2. Use the next available number
3. Fill in all sections
4. Update this README index
5. Submit for review

## References

- [Michael Nygard's article on ADRs](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions)
- [ADR GitHub organization](https://adr.github.io/)
