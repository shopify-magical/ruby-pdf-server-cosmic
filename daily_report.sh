#!/bin/bash
# Daily site snapshot
pdfgen -u "https://news.ycombinator.com" -s dark_matter -o "hn_$(date +%Y%m%d).pdf"
pdfgen -u "https://github.com/trending" -s nebula -o "github_trending_$(date +%Y%m%d).pdf"
echo "Daily reports generated"
