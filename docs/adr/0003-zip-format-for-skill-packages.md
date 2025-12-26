# ADR-0003: ZIP format for .skill packages

## Status

Accepted

## Context

Skills consist of multiple files:

```
my-skill/
├── SKILL.md
├── scripts/
│   └── helper.py
├── references/
│   └── api_docs.md
└── assets/
    └── template.xlsx
```

For distribution and sharing, these files need to be packaged into a single artifact. Requirements:

1. **Single-file distribution**: Easy to share, download, install
2. **Preserve structure**: Directory hierarchy must be maintained
3. **Cross-platform**: Works on Linux, macOS, Windows
4. **Tooling availability**: Users should be able to create packages without special tools
5. **Erlang/OTP support**: Native handling without external dependencies

## Decision

We will use ZIP archives with a `.skill` extension for packaged skills.

A `.skill` file is a standard ZIP archive containing the skill directory structure:

```bash
# Creating a package
zip -r my-skill.skill my-skill/

# The archive contains:
my-skill.skill
├── SKILL.md
├── scripts/helper.py
├── references/api_docs.md
└── assets/template.xlsx
```

Loading uses Erlang's built-in `:zip` module:

```elixir
def extract_skill_file(path) do
  with {:ok, files} <- :zip.unzip(String.to_charlist(path), [:memory]) do
    # Process files...
  end
end
```

The `.skill` extension:

- Clearly identifies the file type
- Allows OS-level file associations
- Distinguishes from generic ZIP archives

## Consequences

### Positive

- ZIP is universally supported across all platforms
- Erlang's `:zip` module requires no external dependencies
- Users can create packages with standard tools (`zip`, file managers)
- Can be extracted and inspected with standard tools
- Supports compression for smaller distribution size
- Memory-efficient extraction (can extract to memory or disk)

### Negative

- No built-in signing or verification (integrity must be handled separately)
- No streaming extraction (entire file must be accessible)
- ZIP has known vulnerabilities (zip bombs, path traversal) requiring validation

### Neutral

- Extension is arbitrary; `.skill` was chosen for clarity
- Compression level is implementation-defined
- No metadata beyond what's in SKILL.md

## Alternatives Considered

### Tarball (.tar.gz)

Standard Unix archive format. Rejected because:

- Less native support on Windows
- Erlang's `:erl_tar` is less battle-tested than `:zip`
- Two-step process (tar then gzip)

### Custom binary format

A purpose-built format with headers, checksums, signatures. Rejected because:

- Requires custom tooling to create packages
- Higher implementation complexity
- No ecosystem tooling support

### No packaging (directory only)

Require skills to always be directories. Rejected because:

- Harder to distribute (must zip anyway, or use git)
- No single-file installation story
- Conflicts with Anthropic's skill distribution plans

### OCI/Container images

Package skills as container images. Rejected because:

- Massive overhead for small file bundles
- Requires container runtime to extract
- Conflates skill content with execution environment

## Security Considerations

When extracting `.skill` files, we must:

1. **Validate paths**: Reject entries with `..` or absolute paths (zip slip attack)
2. **Limit size**: Reject archives or entries exceeding size limits (zip bomb)
3. **Validate structure**: Ensure SKILL.md exists at expected location
4. **Sanitize filenames**: Handle special characters and encoding

## References

- [Erlang :zip module](https://www.erlang.org/doc/man/zip.html)
- [Zip Slip Vulnerability](https://security.snyk.io/research/zip-slip-vulnerability)
- [Anthropic Agent Skills format](https://docs.anthropic.com/en/docs/agents-and-tools/agent-skills)
