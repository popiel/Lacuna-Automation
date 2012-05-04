#!/bin/sh

when=$1
[ -z "$when" ] && when=`date +'%Y-%m-%d'`
what=$2

# ls log/$when/*$what | xargs -n 1 get_json |
(for f in `ls log/$when/*$what`; do
  get_json.pl stack $f || echo $f >&2;
done) \
| sed 's/.*at Client.pm line [0123456789]*...t//' | perl -pe '1 while s/\([^()]*\)//;' | sort | uniq -c | sort -n
