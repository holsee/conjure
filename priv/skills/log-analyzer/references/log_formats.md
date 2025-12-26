# Supported Log Formats

This document describes the log formats supported by the log-analyzer skill.

## JSON Format

### JSON Lines (Recommended)

Each line is a separate JSON object:

```json
{"timestamp": "2024-01-15T10:30:00Z", "level": "INFO", "message": "Request received", "service": "api"}
{"timestamp": "2024-01-15T10:30:01Z", "level": "ERROR", "message": "Database timeout", "service": "api"}
```

### JSON Array

A single JSON array containing log objects:

```json
[
  {"timestamp": "2024-01-15T10:30:00Z", "level": "INFO", "message": "Request received"},
  {"timestamp": "2024-01-15T10:30:01Z", "level": "ERROR", "message": "Database timeout"}
]
```

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `timestamp` | string | ISO 8601 format |
| `level` | string | DEBUG, INFO, WARN, ERROR, FATAL |
| `message` | string | Log message |

### Optional Fields

| Field | Type | Description |
|-------|------|-------------|
| `service` | string | Service name |
| `host` | string | Hostname |
| `request_id` | string | Request correlation ID |
| `user_id` | string | User identifier |
| `duration_ms` | number | Request duration |
| `status_code` | number | HTTP status code |

## Text Format

### Standard Pattern

```
[2024-01-15T10:30:00] INFO Request received: GET /api/users
[2024-01-15T10:30:01] ERROR Database connection failed: timeout
```

### Apache Combined Log Format

```
192.168.1.1 - - [15/Jan/2024:10:30:00 +0000] "GET /api/users HTTP/1.1" 200 1234
```

### Custom Patterns

Use the `--pattern` option with Python regex groups:

```bash
python3 parse_logs.py --format text \
  --pattern "(?P<timestamp>[\d\-T:]+) \[(?P<level>\w+)\] (?P<message>.*)" \
  custom.log
```

## API Response Format

When fetching from REST APIs, the expected response format is:

```json
{
  "logs": [
    {"timestamp": "...", "level": "...", "message": "..."},
    ...
  ],
  "total": 1234,
  "page": 1,
  "per_page": 100
}
```

Or simply an array of log objects.

## Log Levels

| Level | Numeric | Description |
|-------|---------|-------------|
| DEBUG | 0 | Detailed debugging information |
| INFO | 1 | General operational information |
| WARN | 2 | Warning conditions |
| ERROR | 3 | Error conditions |
| FATAL | 4 | Critical failures |

## Examples

### Fetch and Analyze Workflow

```bash
# 1. Fetch logs from API
python3 scripts/fetch_logs.py \
  --endpoint "http://monitoring.example.com/api/logs" \
  --limit 500 \
  --output logs.json

# 2. Analyze for errors
python3 scripts/analyze.py logs.json --errors-only

# 3. Get diagnostics
python3 scripts/analyze.py logs.json --diagnostics
```

### Parse Custom Format

```bash
# Parse logs with custom timestamp format
python3 scripts/parse_logs.py \
  --format text \
  --pattern "(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) (?P<level>\w+): (?P<message>.*)" \
  application.log
```
