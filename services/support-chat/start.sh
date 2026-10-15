#!/bin/sh
set -eu
umask 077
sock=/run/xauxat-support-chat/operator.sock
/usr/bin/tmux -S "$sock" new-session -d -s support -x 160 -y 48 /opt/xauxat-support-chat/run.sh
/usr/bin/tmux -S "$sock" set-option -t support history-limit 200
/usr/bin/tmux -S "$sock" display-message -p '#{pid}' > /run/xauxat-support-chat/server.pid
