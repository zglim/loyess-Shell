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


if [ -z "${DAEMON:-}" ]; then
    if [ -f /usr/local/bin/ssservice ]; then
        DAEMON=/usr/local/bin/ssservice
    elif [ -f /usr/bin/ssservice ]; then
        DAEMON=/usr/bin/ssservice
    fi
fi
NAME=Shadowsocks-rust
CONF=${CONF:-/etc/shadowsocks/config.json}
LOG=${LOG:-/var/log/shadowsocks-rust.log}
PID_DIR=${PID_DIR:-/var/run}
PID_FILE=${PID_FILE:-$PID_DIR/shadowsocks-rust.pid}
RET_VAL=0
DAEMON_ARGS=()

[ -x $DAEMON ] || exit 0

if [ ! -d "$(dirname ${LOG})" ]; then
    mkdir -p $(dirname ${LOG})
fi

check_pid(){
	get_pid=`ps -ef |grep -v grep | grep $DAEMON |awk '{print $2}'`
}

check_pid
if [ -z "$get_pid" ]; then
    if [ -e "$PID_FILE" ]; then
        rm -f "$PID_FILE"
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
    if [ -e "$PID_FILE" ]; then
        if [ -r "$PID_FILE" ]; then
            read PID < "$PID_FILE"
            # Use 'kill -0' for a portable, accurate liveness check instead of
            # relying on /proc, and treat an empty PID file as "not running".
            if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
                return 0
            else
                rm -f "$PID_FILE"
                return 1
            fi
        fi
    else
        return 2
    fi
}

# Build the daemon start arguments into the DAEMON_ARGS array.
#
# This single function owns field detection, config parsing and argument
# assembly so that do_start never has to probe the config on its own:
#   * no 'nameserver' field            -> plain start (no jq dependency)
#   * 'nameserver' present + valid      -> append "--dns <value>"
#   * 'nameserver' present but invalid  -> fail (return 1), start nothing
#
# Returns 0 when the arguments are ready, non-zero when the config is invalid.
get_config_args(){
    # Base arguments are always required.
    DAEMON_ARGS=(server -c "$CONF" -vvv)

    # Cheap presence gate: match the quoted JSON key so we don't false-match a
    # bare substring or a value, and so plain (no-nameserver) deployments keep
    # working even when jq is not installed.
    if ! grep -Eq '"nameserver"[[:space:]]*:' "$CONF"; then
        return 0
    fi

    # From here a 'nameserver' field is declared and MUST resolve to a
    # non-empty string, otherwise we refuse to start a half-configured service.
    if [ ! "$(command -v jq)" ]; then
        echo "Configuration declares 'nameserver' but dependent package 'jq' is missing. Please install it via yum or apt and try again"
        return 1
    fi

    if ! jq -e . "$CONF" >/dev/null 2>&1; then
        echo "$NAME config file $CONF is not valid JSON"
        return 1
    fi

    local NameServerType
    NameServerType=$(jq -r '.nameserver | type' "$CONF" 2>/dev/null)
    if [ "$NameServerType" != "string" ]; then
        echo "Configuration option 'nameserver' must be a non-empty string (got: ${NameServerType:-unknown})"
        return 1
    fi

    NameServer=$(jq -r '.nameserver' "$CONF" 2>/dev/null)
    if [ -z "$NameServer" ]; then
        echo "Configuration option 'nameserver' is present but empty"
        return 1
    fi

    DAEMON_ARGS+=(--dns "$NameServer")
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

    # Resolve (and validate) the start arguments before touching anything. If
    # the config is broken we bail out here without leaving a stale PID file.
    if ! get_config_args; then
        echo "Starting $NAME failed"
        RET_VAL=1
        return 1
    fi

    ulimit -n 51200
    nohup $DAEMON "${DAEMON_ARGS[@]}" > $LOG 2>&1 &

    # Give the daemon a brief moment to come up (or to fail immediately) so the
    # PID we record reflects a process that is actually running.
    sleep 0.5
    check_pid
    if [ -z "$get_pid" ]; then
        rm -f "$PID_FILE"
        echo "Starting $NAME failed"
        RET_VAL=1
        return 1
    fi

    echo "$get_pid" > "$PID_FILE"
    if check_running; then
        echo "Starting $NAME success"
    else
        rm -f "$PID_FILE"
        echo "Starting $NAME failed"
        RET_VAL=1
        return 1
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
