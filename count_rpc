#!/bin/sh

when=$1
[ -z "$when" ] && when=`date +'%Y-%m-%d'`

ls log/$when/* | sed 's/.*\.00.\..*\.//' | sort | uniq -c | sort -n
