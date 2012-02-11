#!/bin/sh
xli $1 &
ipid=$!
echo -n "ANSWER: " 1>&2
read answer
kill $ipid
echo $answer
