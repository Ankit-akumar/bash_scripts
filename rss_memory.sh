#!/bin/bash

# Getting the total RSS memory usage in bytes
rss_memory=$(ps aux | awk 'NR > 1 {sum += $6} END {print sum}')

# Getting the total memory in bytes
total_memory=$(free -b | awk '/^Mem:/{print $2}')

percentage=$(awk "BEGIN {print ($rss_memory / $total_memory) * 100}")

echo "Percentage of RSS memory usage: $percentage%"