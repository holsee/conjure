# Conjure Tutorials

Step-by-step guides for building AI agents with Conjure.

## Learning Path

Start with **Hello World**, then follow the tutorials in order or jump to your use case.

| Tutorial | Time | What You'll Learn |
|----------|------|-------------------|
| [Hello World](hello_world.md) | 10 min | Install Conjure, create an Echo skill, run your first conversation |
| [Local Skills with Claude](using_local_skills_via_claude_api.md) | 30 min | Build a log analyzer skill, deep dive into skill structure |
| [Anthropic Skills API](using_claude_skill_with_elixir_host.md) | 20 min | Use hosted execution for document generation (xlsx, pdf) |
| [Native Elixir Skills](using_elixir_native_skill.md) | 25 min | Build type-safe skills as Elixir modules |
| [Unified Backend Patterns](many_skill_backends_one_agent.md) | 30 min | Combine backends for a complete monitoring solution |
| [Fly.io with Tigris Storage](hello_conjure_flyio.md) | 35 min | Two-phase skill pipeline: Claude generates runbooks, Native executes safely |

## Quick Links

- [Prerequisites](#prerequisites)
- [Example Skills](#example-skills)
- [Getting Help](#getting-help)

## Prerequisites

All tutorials require:

- **Elixir 1.14+** and **Erlang/OTP 25+**
- **Anthropic API key** from [console.anthropic.com](https://console.anthropic.com)

Some tutorials require:

- **Docker 20.10+** (for sandboxed execution)
- **Python 3.8+** (for Python-based skills)
- **Fly.io CLI** (for deployment tutorial)

## Example Skills

The tutorials use these example skills:

| Skill | Purpose | Backend |
|-------|---------|---------|
| `echo` | Simple echo for learning | Local, Docker |
| `log-analyzer` | Production log diagnostics | Local |
| Native Echo | Pure Elixir echo | Native |
| Log Fetcher | REST API log fetching | Native |

## Use Case: Production Monitoring

The tutorials build towards a complete production monitoring solution:

```
┌────────────────────────────────────────────────────────┐
│                    Monitoring Agent                    │
├────────────────────────────────────────────────────────┤
│                                                        │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │   Native     │  │    Local     │  │  Anthropic   │  │
│  │   Backend    │  │   Backend    │  │   Backend    │  │
│  ├──────────────┤  ├──────────────┤  ├──────────────┤  │
│  │ Log Fetcher  │  │ Log Analyzer │  │ Report Gen   │  │
│  │ (REST API)   │  │ (Python)     │  │ (xlsx, pdf)  │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
│                                                        │
└────────────────────────────────────────────────────────┘
```

By the end, you'll have an agent that:
1. Fetches logs from a REST API (Native backend - fast, in-process)
2. Analyzes logs with Python scripts (Local backend - shell execution)
3. Generates incident reports (Anthropic backend - xlsx, pdf)

## Use Case: Incident Response Pipeline

The [Fly.io tutorial](hello_conjure_flyio.md) demonstrates a two-phase skill pipeline pattern:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                            Fly.io Machine                               │
│                                                                         │
│  ┌────────────┐    ┌──────────────────┐    ┌─────────────────────────┐  │
│  │   User     │───▶│  Claude Skill    │───▶│  Runbook Artifact       │  │
│  │  Request   │    │  (Anthropic API) │    │  (JSON in Tigris)       │  │
│  └────────────┘    └──────────────────┘    └───────────┬─────────────┘  │
│                                                        │                │
│                                                        ▼                │
│                                            ┌─────────────────────────┐  │
│                                            │  Native Executor Skill  │  │
│                                            │  - Schema validation    │  │
│                                            │  - Action allow-list    │  │
│                                            │  - Safe dry-run         │  │
│                                            └─────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

Key pattern: **LLM generates structured intent → Native skill executes safely**

- **Claude reasons and plans**: Analyzes incidents, generates structured runbooks
- **Native validates and executes**: Schema enforcement, action allow-listing, deterministic execution
- **Artifact-driven**: JSON runbook is inspectable, testable, replayable, auditable

## Getting Help

- **Issues**: [github.com/holsee/conjure/issues](https://github.com/holsee/conjure/issues)
- **Documentation**: [README](readme.html) and API Reference (module documentation)
- **ADRs**: [Architecture Decision Records](adr-index.html)
