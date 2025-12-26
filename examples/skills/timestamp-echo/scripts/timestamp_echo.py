#!/usr/bin/env python3
"""
Timestamp Echo Skill - Echoes a message with the current timestamp.

Usage:
    python3 timestamp_echo.py [message]
"""

import sys
from datetime import datetime


def timestamp_echo(message: str = "") -> str:
    """Echo a message with the current timestamp."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    if message:
        return f"[{timestamp}] {message}"
    return f"[{timestamp}]"


def main():
    message = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else ""
    result = timestamp_echo(message)
    print(result)


if __name__ == "__main__":
    main()
