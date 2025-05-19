DEVICE=/dev/ttyUSB1   # replace by the terminal used by your device
BAUDS=115200
picocom -b $BAUDS $DEVICE --imap lfcrlf,crcrlf --omap delbs,crlf --send-cmd "ascii-xfr -s -l 30 -n"
