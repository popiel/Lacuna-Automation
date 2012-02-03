while [ 1 ]; do
    $*
    perl -wle 'print "sleeping until ".localtime time+3600;'
    sleep 3600
done
