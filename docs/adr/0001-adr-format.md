# ADR-0001: Use ADR format for architectural decisions

## Status

Accepted

## Context

Conjure involves numerous architectural decisions that affect the library's design, extensibility, and long-term maintainability. These decisions include:

- How skills are loaded and parsed
- Execution environment isolation strategies
- API design philosophy
- Security boundaries

Without documentation, the rationale behind these decisions is lost. Future contributors may:

- Unknowingly revert to previously rejected approaches
- Misunderstand the constraints that shaped the design
- Waste effort re-evaluating settled decisions

## Decision

We will use Architecture Decision Records (ADRs) to document significant architectural decisions.

Each ADR will:

1. Be numbered sequentially (ADR-NNNN)
2. Be stored in `docs/adr/`
3. Follow a consistent format with Status, Context, Decision, and Consequences sections
4. Be immutable once accepted (superseded rather than edited)

A decision is considered "architecturally significant" if it:

- Affects the structure of the codebase
- Constrains future development options
- Has security implications
- Involves non-obvious tradeoffs

## Consequences

### Positive

- Decisions are preserved with their original context
- New contributors can understand why things are the way they are
- Forces explicit articulation of tradeoffs
- Creates a historical record of the project's evolution

### Negative

- Additional documentation overhead
- ADRs can become stale if not maintained
- May slow down decision-making if over-applied

### Neutral

- ADRs are not a substitute for code comments or API documentation
- The index must be kept up to date manually

## References

- [Michael Nygard - Documenting Architecture Decisions](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions)
- [ADR GitHub organization](https://adr.github.io/)
