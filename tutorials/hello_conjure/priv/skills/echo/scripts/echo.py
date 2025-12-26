#!/usr/bin/env python3
import sys
from datetime import datetime

def main():
    if len(sys.argv) < 2:
        print("Usage: echo.py <message>")
        sys.exit(1)

    message = " ".join(sys.argv[1:])
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] Echo: {message}")

if __name__ == "__main__":
    main()
