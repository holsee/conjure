#!/usr/bin/env python3
"""
Fetch logs from a REST API endpoint.

Usage:
    python3 fetch_logs.py --endpoint URL [--limit N] [--level LEVEL] [--output FILE]
"""

import argparse
import json
import sys
from datetime import datetime
from typing import Optional

# For demo purposes, we'll simulate API responses
# In production, you'd use: import requests


def simulate_api_response(endpoint: str, limit: int, level: Optional[str] = None) -> list:
    """Simulate log API response for demo purposes."""
    levels = ["DEBUG", "INFO", "WARN", "ERROR"]
    sample_messages = [
        ("INFO", "Application started successfully"),
        ("INFO", "Request received: GET /api/users"),
        ("DEBUG", "Database connection pool: 5 active, 10 idle"),
        ("WARN", "Slow query detected: 2.5s for user lookup"),
        ("ERROR", "Failed to connect to payment service: timeout"),
        ("INFO", "Request completed: 200 OK in 150ms"),
        ("ERROR", "Unhandled exception in /api/orders: NullPointerException"),
        ("WARN", "Memory usage at 85%"),
        ("INFO", "Cache hit rate: 94.5%"),
        ("ERROR", "Database connection failed: too many connections"),
        ("DEBUG", "Session created for user: user_12345"),
        ("INFO", "Scheduled job completed: cleanup_old_sessions"),
        ("WARN", "Rate limit approaching for IP: 192.168.1.100"),
        ("ERROR", "SSL certificate expires in 7 days"),
        ("INFO", "Health check passed"),
    ]

    logs = []
    base_time = datetime.now()

    for i in range(min(limit, 100)):
        msg_level, msg_text = sample_messages[i % len(sample_messages)]

        if level and msg_level != level:
            continue

        log_entry = {
            "timestamp": (base_time.replace(second=i % 60)).isoformat(),
            "level": msg_level,
            "service": "api-gateway",
            "message": msg_text,
            "request_id": f"req_{1000 + i}",
            "host": f"prod-server-{(i % 3) + 1}",
        }
        logs.append(log_entry)

        if len(logs) >= limit:
            break

    return logs


def fetch_logs(
    endpoint: str,
    limit: int = 100,
    start: Optional[str] = None,
    end: Optional[str] = None,
    level: Optional[str] = None,
) -> list:
    """
    Fetch logs from REST API.

    In production, this would make an actual HTTP request.
    For demo purposes, we simulate the response.
    """
    # In production:
    # params = {"limit": limit}
    # if start: params["start"] = start
    # if end: params["end"] = end
    # if level: params["level"] = level
    # response = requests.get(endpoint, params=params)
    # return response.json()

    # Demo simulation
    return simulate_api_response(endpoint, limit, level)


def main():
    parser = argparse.ArgumentParser(description="Fetch logs from REST API")
    parser.add_argument("--endpoint", required=True, help="REST API endpoint URL")
    parser.add_argument("--limit", type=int, default=100, help="Max logs to fetch")
    parser.add_argument("--start", help="Start time (ISO 8601)")
    parser.add_argument("--end", help="End time (ISO 8601)")
    parser.add_argument("--level", choices=["DEBUG", "INFO", "WARN", "ERROR"],
                       help="Filter by log level")
    parser.add_argument("--output", help="Output file (default: stdout)")

    args = parser.parse_args()

    try:
        logs = fetch_logs(
            endpoint=args.endpoint,
            limit=args.limit,
            start=args.start,
            end=args.end,
            level=args.level,
        )

        output = json.dumps(logs, indent=2)

        if args.output:
            with open(args.output, "w") as f:
                f.write(output)
            print(f"Fetched {len(logs)} logs to {args.output}")
        else:
            print(output)

    except Exception as e:
        print(f"Error fetching logs: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
