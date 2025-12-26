#!/usr/bin/env python3
"""
Parse log files in various formats.

Usage:
    python3 parse_logs.py [--format FORMAT] [--level LEVEL] FILE
"""

import argparse
import json
import re
import sys
from datetime import datetime
from typing import Iterator, Optional


def parse_json_logs(filepath: str) -> Iterator[dict]:
    """Parse JSON lines log file."""
    with open(filepath, "r") as f:
        content = f.read().strip()

        # Try parsing as JSON array first
        try:
            logs = json.loads(content)
            if isinstance(logs, list):
                for log in logs:
                    yield log
                return
        except json.JSONDecodeError:
            pass

        # Parse as JSON lines
        for line in content.split("\n"):
            line = line.strip()
            if line:
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue


def parse_text_logs(filepath: str, pattern: Optional[str] = None) -> Iterator[dict]:
    """Parse plain text log file."""
    # Default pattern: timestamp level message
    default_pattern = r"^\[?(?P<timestamp>[\d\-T:\.]+)\]?\s+(?P<level>\w+)\s+(?P<message>.+)$"
    regex = re.compile(pattern or default_pattern)

    with open(filepath, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            match = regex.match(line)
            if match:
                yield match.groupdict()
            else:
                # Fallback: treat whole line as message
                yield {"message": line, "level": "INFO", "timestamp": datetime.now().isoformat()}


def detect_format(filepath: str) -> str:
    """Auto-detect log file format."""
    with open(filepath, "r") as f:
        first_line = f.readline().strip()

    if first_line.startswith("{") or first_line.startswith("["):
        return "json"
    return "text"


def filter_by_level(logs: Iterator[dict], level: Optional[str]) -> Iterator[dict]:
    """Filter logs by minimum severity level."""
    if not level:
        yield from logs
        return

    level_order = {"DEBUG": 0, "INFO": 1, "WARN": 2, "WARNING": 2, "ERROR": 3, "FATAL": 4}
    min_level = level_order.get(level.upper(), 0)

    for log in logs:
        log_level = log.get("level", "INFO").upper()
        if level_order.get(log_level, 0) >= min_level:
            yield log


def main():
    parser = argparse.ArgumentParser(description="Parse log files")
    parser.add_argument("file", help="Log file to parse")
    parser.add_argument("--format", choices=["json", "text", "auto"], default="auto",
                       help="Log format (default: auto)")
    parser.add_argument("--pattern", help="Regex pattern for text logs")
    parser.add_argument("--level", choices=["DEBUG", "INFO", "WARN", "ERROR"],
                       help="Minimum log level to include")

    args = parser.parse_args()

    try:
        # Detect format if auto
        log_format = args.format
        if log_format == "auto":
            log_format = detect_format(args.file)
            print(f"Detected format: {log_format}", file=sys.stderr)

        # Parse logs
        if log_format == "json":
            logs = parse_json_logs(args.file)
        else:
            logs = parse_text_logs(args.file, args.pattern)

        # Filter by level
        logs = filter_by_level(logs, args.level)

        # Output as JSON
        parsed = list(logs)
        print(json.dumps(parsed, indent=2))
        print(f"\nParsed {len(parsed)} log entries", file=sys.stderr)

    except FileNotFoundError:
        print(f"Error: File not found: {args.file}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error parsing logs: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
