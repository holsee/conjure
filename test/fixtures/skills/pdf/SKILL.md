---
name: pdf
description: |
  Comprehensive PDF manipulation toolkit for extracting text and tables,
  creating new PDFs, merging/splitting documents, and handling forms.
  Use this skill when you need to work with PDF files.
license: MIT
compatibility: python3, poppler-utils
allowed-tools: Bash(pdftotext:*) Read Write
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
