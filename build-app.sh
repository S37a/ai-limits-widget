#!/usr/bin/env bash
set -euo pipefail

swiftc main.swift -o ai-limits-widget -framework Foundation
echo "Built: ai-limits-widget"
echo "Run: ./ai-limits-widget"