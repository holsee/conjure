---
name: pdf
description: |
  Comprehensive PDF manipulation toolkit for extracting text and tables,
  creating new PDFs, merging/splitting documents, and handling forms.
  Use this skill when you need to work with PDF files.
license: MIT
version: "1.0.0"
compatibility:
  products: [claude.ai, claude-code, api]
  packages: [python3, poppler-utils]
allowed_tools: [bash, view, create_file]
---

# PDF Skill

This skill provides comprehensive PDF manipulation capabilities.

## Available Operations

### Text Extraction

Use `pdftotext` or Python's `pdfplumber` to extract text:

```bash
pdftotext input.pdf output.txt
```

### Table Extraction

Use `tabula-py` for extracting tables:

```python
import tabula
tables = tabula.read_pdf("input.pdf", pages="all")
```

## Scripts

See `scripts/extract_text.py` for a complete extraction script.
