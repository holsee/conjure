#!/usr/bin/env python3
"""
Analyze logs for patterns, errors, and anomalies.

Usage:
    python3 analyze.py FILE [--errors-only] [--summary] [--patterns]
"""

import argparse
import json
import sys
from collections import Counter, defaultdict
from datetime import datetime
from typing import Optional


def load_logs(filepath: str) -> list:
    """Load logs from JSON file."""
    with open(filepath, "r") as f:
        content = f.read().strip()
        logs = json.loads(content)
        if isinstance(logs, list):
            return logs
        return [logs]


def analyze_errors(logs: list) -> dict:
    """Analyze error logs."""
    errors = [log for log in logs if log.get("level", "").upper() in ("ERROR", "FATAL")]

    error_messages = Counter()
    error_by_service = defaultdict(int)
    error_by_host = defaultdict(int)

    for error in errors:
        msg = error.get("message", "Unknown error")
        # Extract error type from message
        error_type = msg.split(":")[0] if ":" in msg else msg[:50]
        error_messages[error_type] += 1

        service = error.get("service", "unknown")
        error_by_service[service] += 1

        host = error.get("host", "unknown")
        error_by_host[host] += 1

    return {
        "total_errors": len(errors),
        "unique_errors": len(error_messages),
        "top_errors": error_messages.most_common(10),
        "errors_by_service": dict(error_by_service),
        "errors_by_host": dict(error_by_host),
        "sample_errors": errors[:5],
    }


def analyze_patterns(logs: list) -> dict:
    """Find recurring patterns in logs."""
    message_patterns = Counter()
    level_distribution = Counter()
    service_distribution = Counter()
    hourly_distribution = defaultdict(int)

    for log in logs:
        # Level distribution
        level = log.get("level", "INFO").upper()
        level_distribution[level] += 1

        # Service distribution
        service = log.get("service", "unknown")
        service_distribution[service] += 1

        # Message patterns (first 50 chars)
        msg = log.get("message", "")
        pattern = msg[:50] if len(msg) > 50 else msg
        message_patterns[pattern] += 1

        # Hourly distribution
        try:
            ts = log.get("timestamp", "")
            if ts:
                dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                hourly_distribution[dt.hour] += 1
        except (ValueError, TypeError):
            pass

    return {
        "level_distribution": dict(level_distribution),
        "service_distribution": dict(service_distribution),
        "top_patterns": message_patterns.most_common(10),
        "hourly_distribution": dict(sorted(hourly_distribution.items())),
    }


def generate_summary(logs: list) -> dict:
    """Generate overall log summary."""
    total = len(logs)
    if total == 0:
        return {"total_logs": 0, "status": "No logs to analyze"}

    level_counts = Counter(log.get("level", "INFO").upper() for log in logs)

    error_rate = (level_counts.get("ERROR", 0) + level_counts.get("FATAL", 0)) / total * 100
    warn_rate = level_counts.get("WARN", 0) / total * 100

    # Determine health status
    if error_rate > 10:
        health = "CRITICAL"
        recommendation = "High error rate detected. Immediate investigation required."
    elif error_rate > 5:
        health = "WARNING"
        recommendation = "Elevated error rate. Review error logs for patterns."
    elif warn_rate > 20:
        health = "ATTENTION"
        recommendation = "High warning rate. Monitor for escalation."
    else:
        health = "HEALTHY"
        recommendation = "System operating normally."

    return {
        "total_logs": total,
        "level_breakdown": dict(level_counts),
        "error_rate": f"{error_rate:.2f}%",
        "warn_rate": f"{warn_rate:.2f}%",
        "health_status": health,
        "recommendation": recommendation,
    }


def generate_diagnostics(logs: list) -> list:
    """Generate diagnostic suggestions based on log analysis."""
    diagnostics = []

    errors = [log for log in logs if log.get("level", "").upper() == "ERROR"]

    # Check for common issues
    error_messages = [e.get("message", "") for e in errors]
    error_text = " ".join(error_messages).lower()

    if "timeout" in error_text:
        diagnostics.append({
            "issue": "Timeout errors detected",
            "suggestion": "Check network connectivity and service response times",
            "priority": "HIGH",
        })

    if "connection" in error_text and ("failed" in error_text or "refused" in error_text):
        diagnostics.append({
            "issue": "Connection failures detected",
            "suggestion": "Verify dependent services are running and accessible",
            "priority": "HIGH",
        })

    if "memory" in error_text or "oom" in error_text:
        diagnostics.append({
            "issue": "Memory issues detected",
            "suggestion": "Check memory usage and consider increasing limits",
            "priority": "HIGH",
        })

    if "ssl" in error_text or "certificate" in error_text:
        diagnostics.append({
            "issue": "SSL/Certificate issues detected",
            "suggestion": "Review SSL certificates and expiration dates",
            "priority": "MEDIUM",
        })

    if "rate limit" in error_text:
        diagnostics.append({
            "issue": "Rate limiting detected",
            "suggestion": "Review API usage patterns and rate limit configurations",
            "priority": "MEDIUM",
        })

    if not diagnostics:
        diagnostics.append({
            "issue": "No critical patterns detected",
            "suggestion": "Review individual error messages for specifics",
            "priority": "LOW",
        })

    return diagnostics


def main():
    parser = argparse.ArgumentParser(description="Analyze logs")
    parser.add_argument("file", help="Log file to analyze (JSON format)")
    parser.add_argument("--errors-only", action="store_true",
                       help="Show only error analysis")
    parser.add_argument("--summary", action="store_true",
                       help="Show summary only")
    parser.add_argument("--patterns", action="store_true",
                       help="Show pattern analysis")
    parser.add_argument("--diagnostics", action="store_true",
                       help="Show diagnostic suggestions")

    args = parser.parse_args()

    try:
        logs = load_logs(args.file)
        print(f"Analyzing {len(logs)} log entries...\n", file=sys.stderr)

        result = {}

        if args.summary:
            result["summary"] = generate_summary(logs)
        elif args.errors_only:
            result["errors"] = analyze_errors(logs)
        elif args.patterns:
            result["patterns"] = analyze_patterns(logs)
        elif args.diagnostics:
            result["diagnostics"] = generate_diagnostics(logs)
        else:
            # Full analysis
            result["summary"] = generate_summary(logs)
            result["errors"] = analyze_errors(logs)
            result["patterns"] = analyze_patterns(logs)
            result["diagnostics"] = generate_diagnostics(logs)

        print(json.dumps(result, indent=2))

    except FileNotFoundError:
        print(f"Error: File not found: {args.file}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON in log file: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error analyzing logs: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
