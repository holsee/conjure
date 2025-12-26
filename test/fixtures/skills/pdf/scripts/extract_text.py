#!/usr/bin/env python3
"""Extract text from a PDF file."""

import sys
import pdfplumber

def extract_text(pdf_path):
    with pdfplumber.open(pdf_path) as pdf:
        text = ""
        for page in pdf.pages:
            text += page.extract_text() or ""
            text += "\n"
    return text

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: extract_text.py <pdf_file>")
        sys.exit(1)

    print(extract_text(sys.argv[1]))
