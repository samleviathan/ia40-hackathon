#!/bin/bash
# Compile the macOS helpers the receiver shells out to (Apple Vision OCR, phone screen mirror).
set -euo pipefail
cd "$(dirname "$0")"
for t in ocrfull ocrprobe phonescreen; do
  swiftc -O "$t.swift" -o "$t"
  echo "built tools/$t"
done
