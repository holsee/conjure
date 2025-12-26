---
name: timestamp-echo
description: A simple skill that echoes a message with the current timestamp. Use when asked to echo or repeat a message with a timestamp, get the current time along with a message, or demonstrate basic skill functionality.
---

# Timestamp Echo Skill

A minimal example skill that echoes messages with the current timestamp.

## Usage

To echo a message with a timestamp:

```bash
python3 scripts/timestamp_echo.py "Your message here"
```

## Examples

```bash
# Simple echo with timestamp
python3 scripts/timestamp_echo.py "Hello, World!"
# Output: [2024-12-23 14:30:00] Hello, World!

# Without a message (shows just timestamp)
python3 scripts/timestamp_echo.py
# Output: [2024-12-23 14:30:00]
```

## How It Works

1. The script captures the current timestamp
2. Formats the message with ISO-style timestamp prefix
3. Outputs the result to stdout
