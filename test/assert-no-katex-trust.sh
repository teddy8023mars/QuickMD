#!/bin/bash
# Fails if viewer.js still enables KaTeX trust (which allows javascript: hrefs).
set -euo pipefail
if grep -nE 'trust:\s*true' src/viewer.js; then
  echo "FAIL: 'trust: true' present in src/viewer.js (KaTeX XSS risk)"
  exit 1
fi
echo "PASS: no KaTeX trust:true in src/viewer.js"
