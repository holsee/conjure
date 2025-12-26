# ADR-0013: Docker infrastructure and image distribution

## Status

Proposed

## Context

The Docker executor (`Conjure.Executor.Docker`) is the recommended production execution backend (ADR-0010). Currently:

1. The Dockerfile is embedded as a string in `docker.ex`
2. No pre-built images are available
3. Users must build the image themselves
4. The `priv/docker/` directory does not exist

This creates friction for adoption:

```elixir
# Current state: users must build before using
Conjure.Executor.Docker.build_image()  # Builds from embedded Dockerfile
```

Production deployments would benefit from:

- Pre-built, tested images
- Versioned image tags matching library versions
- CI/CD integration for automated builds
- Customization options for enterprise environments

## Decision

We will establish Docker infrastructure with the following components:

### 1. External Dockerfile

Move the Dockerfile from embedded string to `priv/docker/Dockerfile`:

```dockerfile
# priv/docker/Dockerfile
FROM ubuntu:24.04

LABEL org.opencontainers.image.source="https://github.com/holsee/conjure"
LABEL org.opencontainers.image.description="Conjure sandbox execution environment"
LABEL org.opencontainers.image.version="${VERSION}"

# System packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.12 python3-pip python3-venv \
    nodejs npm \
    bash git curl wget jq \
    poppler-utils qpdf \
    && rm -rf /var/lib/apt/lists/*

# Python packages (matching Anthropic's environment)
RUN pip3 install --break-system-packages \
    pyarrow openpyxl xlsxwriter xlrd pillow \
    python-pptx python-docx pypdf pdfplumber \
    pypdfium2 pdf2image pdfkit tabula-py \
    reportlab img2pdf pandas numpy matplotlib \
    pyyaml requests beautifulsoup4

# Non-root user for security
RUN useradd -m -s /bin/bash -u 1000 sandbox
USER sandbox
WORKDIR /workspace

ENV PYTHONUNBUFFERED=1
ENV NODE_ENV=production
```

### 2. Image Variants

Provide multiple image variants for different use cases:

```
priv/docker/
├── Dockerfile              # Default full-featured image
├── Dockerfile.minimal      # Minimal image (bash only)
├── Dockerfile.python       # Python-focused (no Node.js)
└── Dockerfile.node         # Node.js-focused (no Python)
```

### 3. Image Distribution

Publish images to GitHub Container Registry (ghcr.io):

- `ghcr.io/holsee/conjure-sandbox:latest`
- `ghcr.io/holsee/conjure-sandbox:0.1.0`
- `ghcr.io/holsee/conjure-sandbox:0.1.0-minimal`
- `ghcr.io/holsee/conjure-sandbox:0.1.0-python`

### 4. GitHub Actions Workflow

```yaml
# .github/workflows/docker.yml
name: Docker Images

on:
  release:
    types: [published]
  push:
    branches: [main]
    paths: ['priv/docker/**']

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v5
        with:
          context: .
          file: priv/docker/Dockerfile
          push: true
          tags: |
            ghcr.io/${{ github.repository_owner }}/conjure-sandbox:${{ github.ref_name }}
            ghcr.io/${{ github.repository_owner }}/conjure-sandbox:latest
```

### 5. Default Image Configuration

Update `Conjure.Executor.Docker` to use published images by default:

```elixir
@default_image "ghcr.io/holsee/conjure-sandbox:latest"

# With fallback to local build
def ensure_image(opts \\ []) do
  image = Keyword.get(opts, :image, @default_image)

  case pull_image(image) do
    :ok -> {:ok, image}
    {:error, _} -> build_image(opts)  # Fallback to local build
  end
end
```

### 6. Mix Task Integration

The `mix conjure.docker.build` task reads from `priv/docker/`:

```elixir
def run(args) do
  dockerfile = Path.join(:code.priv_dir(:conjure), "docker/Dockerfile")
  # Build using external Dockerfile
end
```

## Consequences

### Positive

- Faster onboarding—users can pull pre-built images
- Versioned images ensure reproducibility
- CI/CD builds ensure images are tested
- External Dockerfile enables customization
- Multiple variants serve different needs

### Negative

- Must maintain image builds in CI
- Registry costs (GitHub provides generous free tier)
- Image size concerns (full image ~1GB)
- Version coordination between library and images

### Neutral

- Users can still build locally if preferred
- Enterprise users can fork and customize
- Image updates independent of library releases possible

## Alternatives Considered

### Docker Hub Distribution

Using Docker Hub instead of GHCR. Rejected because:

- GHCR integrates better with GitHub Actions
- No rate limiting for authenticated users
- Keeps everything in one ecosystem

### No Pre-built Images

Require users to always build locally. Rejected because:

- Significant friction for new users
- Build times slow down development
- Inconsistent environments across users

### Single Image Only

Only provide one full-featured image. Partially accepted—we start with variants but prioritize the default image.

## References

- [ADR-0010: Docker as production executor](0010-docker-production-executor.md)
- [GitHub Container Registry documentation](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
- [Docker multi-platform builds](https://docs.docker.com/build/building/multi-platform/)
