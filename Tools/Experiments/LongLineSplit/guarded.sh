#!/bin/zsh
# usage: guarded.sh <max_rss_mb> <max_seconds> <command...>
# Runs one process in the foreground of this script; kills it if its memory or time goes over.
maxmb=$1; maxs=$2; shift 2
"$@" &
pid=$!
peak=0
start=$SECONDS
while kill -0 $pid 2>/dev/null; do
  rss=$(ps -o rss= -p $pid 2>/dev/null | tr -d ' ')
  [[ -n "$rss" ]] && (( rss/1024 > peak )) && peak=$(( rss/1024 ))
  if [[ -n "$rss" ]] && (( rss/1024 > maxmb )); then kill -9 $pid; echo "GUARD: killed at ${peak} MB (limit ${maxmb})"; wait $pid 2>/dev/null; exit 99; fi
  if (( SECONDS - start > maxs )); then kill -9 $pid; echo "GUARD: killed after ${maxs}s (peak ${peak} MB)"; wait $pid 2>/dev/null; exit 98; fi
  sleep 0.3
done
wait $pid
code=$?
echo "GUARD: exit=${code} peak=${peak} MB"
exit $code
