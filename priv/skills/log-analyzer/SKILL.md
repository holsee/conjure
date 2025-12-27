---
name: log-analyzer
description: |
  Production log analysis and diagnostics skill. Use this skill when asked to:
  - Fetch logs from a monitoring API
  - Analyze log patterns and errors
  - Diagnose production issues
  - Generate log summaries and statistics
license: MIT
compatibility: python3, requests
allowed-tools: Bash(python3:*) Read Write
---

# Log Analyzer Skill

A production monitoring skill for fetching, analyzing, and diagnosing issues from application logs.

## Available Scripts

### 1. Fetch Logs (`fetch_logs.py`)

Fetches logs from a REST API endpoint.

```bash
# Fetch last 100 logs
python3 scripts/fetch_logs.py --endpoint "http://localhost:8080/api/logs" --limit 100

# Fetch logs with time range
python3 scripts/fetch_logs.py --endpoint "http://localhost:8080/api/logs" \
  --start "2024-01-15T00:00:00" --end "2024-01-15T23:59:59"

# Fetch logs by severity
python3 scripts/fetch_logs.py --endpoint "http://localhost:8080/api/logs" \
  --level ERROR
```

**Options:**
- `--endpoint` - REST API URL for logs (required)
- `--limit` - Maximum number of logs to fetch (default: 100)
- `--start` - Start time (ISO 8601 format)
- `--end` - End time (ISO 8601 format)
- `--level` - Filter by log level (DEBUG, INFO, WARN, ERROR)
- `--output` - Output file (default: stdout)

### 2. Parse Logs (`parse_logs.py`)

Parses log files in various formats.

```bash
# Parse JSON logs
python3 scripts/parse_logs.py --format json logs.json

# Parse text logs with pattern
python3 scripts/parse_logs.py --format text --pattern "%(timestamp)s %(level)s %(message)s" app.log

# Parse and filter by level
python3 scripts/parse_logs.py logs.json --level ERROR
```

**Supported Formats:**
- `json` - JSON lines format
- `text` - Plain text with pattern
- `auto` - Auto-detect format

### 3. Analyze Logs (`analyze.py`)

Analyzes logs for patterns, errors, and anomalies.

```bash
# Full analysis
python3 scripts/analyze.py logs.json

# Error analysis only
python3 scripts/analyze.py logs.json --errors-only

# Generate summary
python3 scripts/analyze.py logs.json --summary

# Find patterns
python3 scripts/analyze.py logs.json --patterns
```

**Analysis Types:**
- Error frequency and patterns
- Response time anomalies
- Request volume trends
- Common error messages
- Suggested diagnostics

## Example Workflow

1. **Fetch recent logs:**
   ```bash
   python3 scripts/fetch_logs.py --endpoint "http://api.example.com/logs" \
     --limit 500 --output recent_logs.json
   ```

2. **Analyze for errors:**
   ```bash
   python3 scripts/analyze.py recent_logs.json --errors-only
   ```

3. **Get summary:**
   ```bash
   python3 scripts/analyze.py recent_logs.json --summary
   ```

## Log Format Reference

See `references/log_formats.md` for supported log formats and examples.

## Tips

- Always start by fetching recent logs with a reasonable limit
- Use `--errors-only` for quick triage
- Use `--summary` to understand overall health
- Check `--patterns` to find recurring issues
