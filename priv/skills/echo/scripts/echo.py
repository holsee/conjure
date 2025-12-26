#!/usr/bin/env python3
"""
Echo Skill - A simple script that echoes messages back.

Usage:
    python3 echo.py "Your message here"
"""

import sys
from datetime import datetime


def echo(message: str) -> str:
    """Echo a message with a timestamp."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    return f"[{timestamp}] Echo: {message}"


def main():
    if len(sys.argv) < 2:
        print("Usage: echo.py <message>")
        print("Example: echo.py 'Hello, World!'")
        sys.exit(1)

    message = " ".join(sys.argv[1:])
    result = echo(message)
    print(result)


if __name__ == "__main__":
    main()
