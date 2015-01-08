#! /bin/bash

# Quick hack pending block/splitting support in wdt itself
# Source of this file is fbcode/wdt/wcp.sh
# This copies a single file - if you have a lot of files - use wdt directly
# (without the splitting step - don't make a compressed archive!)


usage="Usage:\n
`basename $0` [-p portbase] [-l loglevel] [-n] singlebigsrcfile
[user@]desthost:directory\n
  p : port base to use (8 sockets used by default from that port or 22356\n
  l : logging verbosity level to use\n
  n : no compression (gzip by default)\n
The wdt binary should be in the path on both source and destination\n
And wdt ports (22356-22364 unless specified with -p) should be available
on the destination"

# Defaults
MINLOGLEVEL=2
PORTBASE=22356
DOCOMPRESSION=1

while getopts "p:l:h" opt
do case "$opt" in
        p)  PORTBASE="$OPTARG";;
        l)  MINLOGLEVEL="$OPTARG";;
        n)  DOCOMPRESSION=0;;
        h)  echo -e $usage; exit 1;;
        \?) echo -e $usage; exit 1;;
  esac
done
shift $((OPTIND-1))

if [ $# -ne 2 ] ; then
    echo -e $usage
    exit 1
fi

SRCPATH=$1
if [ ! -r $SRCPATH ] ; then
    echo "First argument ($SRCPATH) must be a readable file"
    exit 2
fi

DIR=`mktemp -d`
REMOTE=`echo $2|sed -e 's/^.*@//' -e 's/:.*//'`
SSHREMOTE=`echo $2|sed -e 's/:.*//'`
REMOTEDIR=`echo $2|sed -e 's/.*://'`
if [ -z "$REMOTEDIR" ] ; then
  REMOTEDIR=.
fi

FILENAME=`basename $SRCPATH`
SIZE=`stat -L -c %s $SRCPATH`
if [ $? -ne 0 ] ; then
  echo "Error stating $SRCPATH. aborting."
  exit 1
fi

echo "Copying $FILENAME ($SRCPATH) to $REMOTE (using $SSHREMOTE in $REMOTEDIR)"

# Here we try to start asynchronously - the effect is things may fail on the
# server side and we won't know - also pkill may not be fast enough and
# data may still be sent to the previous process
echo "Starting destination side server"
if [ $DOCOMPRESSION -eq 1 ] ; then
    # Gzip compression:
    ssh -f $SSHREMOTE "pkill wdt; mkdir -p $REMOTEDIR; cd $REMOTEDIR; rm -f wdtTMP; wdt --minloglevel=$MINLOGLEVEL --port $PORTBASE && cat wdtTMP* | time gzip -d -c > $FILENAME && rm wdtTMP* ; echo 'Complete!';date; echo 'Dst checksum'; md5sum $FILENAME"
else
    # No compression:
    ssh -f $SSHREMOTE "pkill wdt; mkdir -p $REMOTEDIR; cd $REMOTEDIR; rm -f wdtTMP; wdt --minloglevel=$MINLOGLEVEL && cat wdtTMP* > $FILENAME && rm wdtTMP* ; echo 'Complete!';date; echo 'Dst checksum'; md5sum $FILENAME"
fi
#REMOTEPID=$!

# Start counting time after ssh because ssh can ask for credentials/take a while
START_NANO=`date +%s%N`
START_MS=`expr $START_NANO / 1000000`
echo "Starting at `date` ($START_MS)"

# We compress so most likely we'll have less blocks than that
SPLIT=`expr $SIZE / 48 / 1024 + 1`

if [ $DOCOMPRESSION ] ; then
  # Gzip
  SPLIT=`expr $SIZE / 48 / 1024 + 1`
  echo "Compressing $SRCPATH ($SIZE) up to 48 ways ($SPLIT k chunks) in $DIR"
  time gzip -1 -c $SRCPATH | (cd $DIR ; time split -b ${SPLIT}K - wdtTMP )
  # LZ4
  #time lz4 -3 -z $SRCPATH - | (cd $DIR ; time split -b ${SPLIT}K - wdtTMP )
else
  # No compression
  SPLIT=`expr $SIZE / 24 / 1024 + 1`
  echo "Splitting $SRCPATH ($SIZE) 24 ways ($SPLIT kbyte chunks) in $DIR"
  cat $SRCPATH | (cd $DIR ; time split -b ${SPLIT}K - wdtTMP )
fi

date "+%s.%N"
time wdt --minloglevel=$MINLOGLEVEL --directory $DIR \
    --destination $REMOTE  --port $PORTBASE --ipv6=false # try both v4 and v6
STATUS=$?

END_NANO=`date +%s%N`
END_MS=`expr $END_NANO / 1000000`
DURATION=`expr $END_MS - $START_MS`
RATE=`expr 1000 \* $SIZE / 1024 / 1024 / $DURATION`

if [ $STATUS -eq 0 ] ; then
    echo "Succesfull transfer"
else
    echo "Failure (code $STATUS)"
fi

echo "All done client side! cleanup..."
rm -r $DIR &
echo -n "e" | nc $REMOTE $PORTBASE

echo "Overall transfer @ $RATE Mbytes/sec ($DURATION ms for $SIZE uncompressed)"

echo "Source checksum:"
md5sum $SRCPATH

exit $STATUS
