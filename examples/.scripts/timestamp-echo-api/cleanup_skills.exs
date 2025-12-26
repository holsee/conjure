#!/usr/bin/env elixir
# Delete orphaned custom skills

api_key = System.get_env("ANTHROPIC_API_KEY")
headers = [
  {"x-api-key", api_key},
  {"anthropic-version", "2023-06-01"}
] ++ Conjure.API.Anthropic.beta_headers()

{:ok, resp} = Req.get("https://api.anthropic.com/v1/skills?source=custom&limit=20", headers: headers)
IO.inspect(resp.body, label: "Skills")

for skill <- resp.body["data"] || [] do
  skill_id = skill["id"]
  IO.puts("Deleting: #{skill_id} (#{skill["display_title"]})")

  # Get versions
  {:ok, versions_resp} = Req.get("https://api.anthropic.com/v1/skills/#{skill_id}/versions", headers: headers)

  # Delete each version
  for v <- versions_resp.body["data"] || [] do
    IO.puts("  Deleting version: #{v["version"]}")
    Req.delete("https://api.anthropic.com/v1/skills/#{skill_id}/versions/#{v["version"]}", headers: headers)
  end

  # Now delete skill
  Req.delete("https://api.anthropic.com/v1/skills/#{skill_id}", headers: headers)
end

IO.puts("Done")
