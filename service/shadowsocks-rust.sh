#!/usr/bin/env bash
# chkconfig: 2345 90 10
# description: A secure socks5 proxy, designed to protect your Internet traffic.

### BEGIN INIT INFO
# Provides:          Shadowsocks-rust
# Required-Start:    $network $syslog
# Required-Stop:     $network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Fast tunnel proxy that helps you bypass firewalls
# Description:       Start or stop the Shadowsocks-rust server
### END INIT INFO


if [ -f /usr/local/bin/ssservice ]; then
    DAEMON=/usr/local/bin/ssservice
elif [ -f /usr/bin/ssservice ]; then
    DAEMON=/usr/bin/ssservice
fi
NAME=Shadowsocks-rust
CONF=/etc/shadowsocks/config.json
LOG=/var/log/shadowsocks-rust.log
PID_DIR=/var/run
PID_FILE=$PID_DIR/shadowsocks-rust.pid
RET_VAL=0

[ -x $DAEMON ] || exit 0

if [ ! -d "$(dirname ${LOG})" ]; then
    mkdir -p $(dirname ${LOG})
fi

check_pid(){
	get_pid=`ps -ef |grep -v grep | grep $DAEMON |awk '{print $2}'`
}

check_pid
if [ -z $get_pid ]; then
    if [ -e $PID_FILE ]; then
        rm -f $PID_FILE
    fi
fi

if [ ! -d $PID_DIR ]; then
    mkdir -p $PID_DIR
    if [ $? -ne 0 ]; then
        echo "Creating PID directory $PID_DIR failed"
        exit 1
    fi
fi

if [ ! -f $CONF ]; then
    echo "$NAME config file $CONF not found"
     exit 1
fi

check_running() {
    if [ -e $PID_FILE ]; then
        if [ -r $PID_FILE ]; then
            read PID < $PID_FILE
            if [ -d "/proc/$PID" ]; then
                return 0
            else
                rm -f $PID_FILE
                return 1
            fi
        fi
    else
        return 2
    fi
}

get_config_args(){
    local JsonFilePath=$1

    if [ ! -f "$JsonFilePath" ]; then
        echo "$NAME config file $JsonFilePath not found"
        return 2
    fi

    if [ ! "$(command -v jq)" ]; then
        echo "Cannot find dependent package 'jq' Please use yum or apt to install and try again"
        return 2
    fi

    # Check whether 'nameserver' key exists in the JSON config.
    # jq 'has("nameserver")' prints "true" or "false" without erroring on missing keys.
    local has_key
    has_key=$(jq 'has("nameserver")' "$JsonFilePath" 2>/dev/null)
    if [ "$has_key" != "true" ]; then
        # nameserver field not present — normal, caller should start without --dns
        NameServer=""
        return 1
    fi

    # nameserver key exists; extract value (jq returns "null" for null values,
    # and empty string via `// empty` when the value is null/missing).
    # Use direct extraction: if the value is null, jq -r prints "null".
    NameServer=$(jq -r '.nameserver // empty' "$JsonFilePath" 2>/dev/null)

    if [ -z "$NameServer" ]; then
        echo "Error: 'nameserver' is defined in config but value is empty or null"
        return 2
    fi

    # Basic sanity: reject values that look like they are not a valid address/host
    # (e.g. raw JSON fragments, booleans, objects). A valid nameserver should be
    # an IP address, hostname, or a DNS URI like "tls://8.8.8.8".
    case "$NameServer" in
        *\{*|*\}*|*true*|*false*|*null*|*\[*|*\]*)
            echo "Error: 'nameserver' value appears malformed: $NameServer"
            return 2
            ;;
    esac

    return 0
}

do_status() {
    check_running
    case $? in
        0)
        echo "$NAME (pid $PID) is running."
        ;;
        1|2)
        echo "$NAME is stopped"
        RET_VAL=1
        ;;
    esac
}

do_start() {
    if check_running; then
        echo "$NAME (pid $PID) is already running."
        return 0
    fi
    ulimit -n 51200

    # Use get_config_args as the single source of truth for nameserver detection.
    # Return codes: 0 = valid nameserver found, 1 = not present, 2 = error
    local dns_args=""
    get_config_args "$CONF"
    local rc=$?
    if [ $rc -eq 0 ]; then
        # nameserver present and valid
        dns_args="--dns $NameServer"
    elif [ $rc -eq 2 ]; then
        # nameserver present but invalid — abort without starting
        echo "Starting $NAME failed: nameserver configuration error"
        RET_VAL=1
        return 1
    fi
    # rc == 1: no nameserver, proceed with plain start (dns_args stays empty)

    nohup $DAEMON server -c "$CONF" $dns_args -vvv > "$LOG" 2>&1 &
    sleep 0.2

    check_pid
    if [ -n "$get_pid" ]; then
        echo "$get_pid" > "$PID_FILE"
    fi

    if check_running; then
        echo "Starting $NAME success"
    else
        # Ensure no stale PID file is left behind on failure
        rm -f "$PID_FILE"
        echo "Starting $NAME failed"
        RET_VAL=1
    fi
}

do_stop() {
    if check_running; then
        kill -9 $PID
        rm -f $PID_FILE
        echo "Stopping $NAME success"
    else
        echo "$NAME is stopped"
        RET_VAL=1
    fi
}

do_restart() {
    do_stop
    sleep 0.5
    do_start
}

case "$1" in
    start|stop|restart|status)
    do_$1
    ;;
    *)
    echo "Usage: $0 { start | stop | restart | status }"
    RET_VAL=1
    ;;
esac

exit $RET_VAL