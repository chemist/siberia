#!/bin/bash

while read line
do
  echo curl "http://localhost:8000/stream/a" -d \'$line\'
done

# cat stations | sed s/d\"\ :\ /d\"\ :\ \"/ | sed s/,/\",/ | ./load.sh | sh
