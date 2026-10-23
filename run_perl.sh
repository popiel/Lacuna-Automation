#!/usr/bin/env bash
# Runs Strawberry Perl with the environment it needs (OpenSSL DLLs live in c/bin).
# Usage: ./run_perl.sh <perl options and script + args>
# Example: ./run_perl.sh star_db_util.pl --help

STRAWBERRY="${STRAWBERRY:-/c/Strawberry}"

if [ ! -x "$STRAWBERRY/perl/bin/perl.exe" ]; then
  echo "error: Strawberry Perl not found at $STRAWBERRY/perl/bin/perl.exe" >&2
  echo "Set STRAWBERRY to the Strawberry install root and retry." >&2
  exit 1
fi

export PATH="$STRAWBERRY/c/bin:$STRAWBERRY/perl/site/bin:$STRAWBERRY/perl/bin:$PATH"

exec "$STRAWBERRY/perl/bin/perl.exe" "$@"
