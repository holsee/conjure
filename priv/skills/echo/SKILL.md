---
name: echo
description: |
  A simple echo skill for testing and learning. Use this skill when asked to:
  - Echo or repeat a message
  - Test that skills are working correctly
  - Demonstrate basic skill functionality
license: MIT
compatibility: python3
allowed-tools: Bash(python3:*) Read
---

# Echo Skill

A minimal skill that echoes messages back. Perfect for learning how Conjure works.

## Usage

To echo a message, run the echo script:

```bash
python3 scripts/echo.py "Your message here"
```

The script will print the message back with a timestamp.

## Examples

```bash
# Simple echo
python3 scripts/echo.py "Hello, World!"
# Output: [2024-01-15 10:30:00] Echo: Hello, World!

# Multi-word message
python3 scripts/echo.py "This is a test message"
# Output: [2024-01-15 10:30:01] Echo: This is a test message
```

## How It Works

1. The script receives a message as a command-line argument
2. It formats the message with a timestamp
3. It prints the formatted message to stdout

This simple flow demonstrates the core pattern of all Conjure skills:
- Claude reads the SKILL.md to understand capabilities
- Claude uses `bash_tool` to execute scripts
- Results are returned to continue the conversation
