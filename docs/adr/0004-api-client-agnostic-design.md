# ADR-0004: API-client agnostic design

## Status

Accepted

## Context

Conjure needs to interact with the Claude API to:

1. Send system prompts with skill information
2. Receive responses containing tool calls
3. Send tool results back to Claude

The Elixir ecosystem has multiple HTTP clients and API wrapper patterns:

- HTTPoison, Finch, Req, Mint (HTTP clients)
- Tesla (middleware-based client)
- Custom wrappers with retry logic, telemetry, authentication
- Official Anthropic SDKs (when available for Elixir)

Different organizations have different:

- HTTP client preferences
- Authentication patterns (API keys, OAuth, service accounts)
- Retry and backoff strategies
- Rate limiting requirements
- Observability integrations

Building a Claude API client into Conjure would:

- Force HTTP client choice on users
- Duplicate effort with existing clients
- Create maintenance burden for API changes
- Limit flexibility for enterprise deployments

## Decision

We will not implement a Claude API client. Conjure will be API-client agnostic.

Instead, we will:

1. **Accept callbacks** for API interactions:

```elixir
Conjure.Conversation.run_loop(
  messages,
  skills,
  fn messages -> MyApp.Claude.call(messages) end,  # User provides this
  opts
)
```

2. **Provide helper functions** for request/response formatting:

```elixir
# Build the tools parameter for API requests
tools = Conjure.API.build_tools_param(skills)

# Build system prompt with skills fragment
system = Conjure.API.build_system_prompt(base_prompt, skills)

# Parse tool_use blocks from response
{:ok, parsed} = Conjure.API.parse_response(api_response)

# Format tool results for next request
message = Conjure.API.format_tool_results_message(results)
```

3. **Document integration patterns** for common clients in the README and examples.

## Consequences

### Positive

- Users keep full control over HTTP layer
- Works with any Claude API client or wrapper
- No HTTP client dependency in Conjure
- Users can apply their own retry, rate limiting, caching strategies
- Supports custom authentication (API keys, OAuth, etc.)
- Future-proof against API changes (users update their client)

### Negative

- More setup required for new users
- Users must understand Claude API message format
- No "batteries included" experience
- Example code needed for each HTTP client

### Neutral

- Helper functions handle the Conjure-specific formatting
- Response parsing is provided but optional
- Users can bypass helpers for custom integrations

## Alternatives Considered

### Built-in HTTP client with optional override

Provide a default client that users can replace. Rejected because:

- Still forces an HTTP dependency
- "Optional override" patterns are confusing
- Maintenance burden for a non-core feature

### Behaviour-based client abstraction

Define a `Conjure.APIClient` behaviour. Rejected because:

- Over-engineered for simple HTTP calls
- Callbacks are simpler and more flexible
- Behaviours imply Conjure manages the client lifecycle

### Require a specific client library

Depend on a popular client like Req. Rejected because:

- Forces dependency choice on all users
- May conflict with existing project setup
- Limits enterprise customization

## Integration Examples

### With Req

```elixir
defp call_claude(messages, system, tools) do
  Req.post!("https://api.anthropic.com/v1/messages",
    json: %{model: "claude-sonnet-4-5-20250929", system: system, messages: messages, tools: tools},
    headers: [{"x-api-key", api_key()}, {"anthropic-version", "2023-06-01"}]
  ).body
end
```

### With HTTPoison

```elixir
defp call_claude(messages, system, tools) do
  body = Jason.encode!(%{model: "claude-sonnet-4-5-20250929", ...})
  {:ok, resp} = HTTPoison.post(url, body, headers)
  Jason.decode!(resp.body)
end
```

## References

- [Anthropic API Documentation](https://docs.anthropic.com/en/api)
- [Req HTTP client](https://hexdocs.pm/req)
- [Tesla middleware client](https://hexdocs.pm/tesla)
