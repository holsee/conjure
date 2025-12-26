defmodule Conjure.Prompt do
  @moduledoc """
  Generates system prompt fragments for skill discovery.

  This module creates the XML-formatted content that should be appended
  to your system prompt to enable Claude to discover and use available skills.

  ## Prompt Structure

  The generated prompt includes:
  - A description of the skills system
  - List of available skills with name, description, and location
  - Instructions for skill usage

  ## Example

      skills = Conjure.load("/path/to/skills")
      prompt_fragment = Conjure.Prompt.generate(skills)

      system_prompt = \"\"\"
      You are a helpful assistant.

      \#{prompt_fragment}
      \"\"\"

  ## Token Efficiency

  Only metadata (name, description, location) is included per skill.
  Full skill content is loaded on-demand via progressive disclosure.
  """

  alias Conjure.Skill

  @doc """
  Generates the complete skills system prompt fragment.

  This combines the skills description, available skills listing, and
  usage instructions into a single XML block.

  ## Options

  * `:include_instructions` - Whether to include usage instructions (default: true)
  """
  @spec generate([Skill.t()], keyword()) :: String.t()
  def generate(skills, opts \\ []) do
    include_instructions = Keyword.get(opts, :include_instructions, true)

    [
      "<skills>",
      skills_description(),
      "",
      available_skills_block(skills),
      if(include_instructions, do: ["\n", skill_usage_instructions()], else: []),
      "</skills>"
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  @doc """
  Generates the <available_skills> XML block.
  """
  @spec available_skills_block([Skill.t()]) :: String.t()
  def available_skills_block(skills) do
    skill_entries = Enum.map_join(skills, "\n\n", &format_skill/1)

    """
    <available_skills>
    #{skill_entries}
    </available_skills>\
    """
  end

  @doc """
  Formats a single skill for the available_skills block.
  """
  @spec format_skill(Skill.t()) :: String.t()
  def format_skill(%Skill{} = skill) do
    description = escape_xml(skill.description)
    location = Skill.skill_md_path(skill)

    """
    <skill>
    <name>#{skill.name}</name>
    <description>#{description}</description>
    <location>#{location}</location>
    </skill>\
    """
  end

  @doc """
  Generates the skills description text.
  """
  @spec skills_description() :: String.t()
  def skills_description do
    """
    <skills_description>
    Claude has access to a set of skills that extend its capabilities for specialized tasks.
    Skills are loaded automatically when relevant to the task at hand.
    To use a skill, Claude should first read the SKILL.md file using the view tool to understand
    how to use the skill, then follow the instructions within.
    </skills_description>\
    """
  end

  @doc """
  Generates skill usage instructions.
  """
  @spec skill_usage_instructions(keyword()) :: String.t()
  def skill_usage_instructions(_opts \\ []) do
    """
    <skill_usage_instructions>
    When a task matches a skill's description:
    1. Use the view tool to read the skill's SKILL.md file at the provided location
    2. Follow the instructions in the skill
    3. Use additional resources (scripts/, references/) as directed by the skill
    4. If the skill requires specific tools, ensure they are available before proceeding
    </skill_usage_instructions>\
    """
  end

  @doc """
  Counts the approximate tokens for the skills prompt.

  This is a rough estimate assuming ~4 characters per token.
  """
  @spec estimate_tokens([Skill.t()]) :: pos_integer()
  def estimate_tokens(skills) do
    prompt = generate(skills)
    # Rough estimate: ~4 characters per token for English text
    div(String.length(prompt), 4)
  end

  # Private helpers

  defp escape_xml(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp escape_xml(text), do: to_string(text)
end
