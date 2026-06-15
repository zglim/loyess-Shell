#!/usr/bin/env bash
# chkconfig: 2345 90 10
# description: A secure socks5 proxy, designed to protect your Internet traffic.

### BEGIN INIT INFO
# Provides:          Go-shadowsocks2
# Required-Start:    $network $syslog
# Required-Stop:     $network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Fast tunnel proxy that helps you bypass firewalls
# Description:       Start or stop the go-shadowsocks2 server
### END INIT INFO


if [ -f /usr/local/bin/go-shadowsocks2 ]; then
    DAEMON=/usr/local/bin/go-shadowsocks2
elif [ -f /usr/bin/go-shadowsocks2 ]; then
    DAEMON=/usr/bin/go-shadowsocks2
fi
NAME=Go-shadowsocks2
CONF=/etc/shadowsocks/config.json
LOG=/var/log/go-shadowsocks2.log
PID_DIR=/var/run
PID_FILE=$PID_DIR/go-shadowsocks2.pid
RET_VAL=0
# Single source of truth for "is a plugin configured": set by get_config_args,
# consumed by do_start / do_stop. 0 = no plugin, 1 = plugin enabled.
UsePlugin=0

[ -x $DAEMON ] || exit 0

if [ ! -d "$(dirname ${LOG})" ]; then
    mkdir -p $(dirname ${LOG})
fi

check_pid(){
    local FindText=$1

	GET_PID=`ps -ef | grep -v grep | grep $FindText | awk '{print $2}'`
}

check_pid_file(){
    local Pid=$1
    local PidFile=$2

    if [ -z $Pid ]; then
        if [ -e $PidFile ]; then
            rm -f $PidFile
        fi
    fi
}

create_pid_dir(){
    local PidDir=$1

    if [ ! -d $PidDir ]; then
        mkdir -p $PidDir
        if [ $? -ne 0 ]; then
            echo "Creating PID directory $PidDir failed"
            exit 1
        fi
    fi
}

get_config_args(){
    local JsonFilePath=$1

    if [ ! -f $JsonFilePath ]; then
        echo "$NAME config file $JsonFilePath not found"
        exit 1
    fi

    if [ ! "$(command -v jq)" ]; then
        echo "Cannot find dependent package 'jq' Please use yum or apt to install and try again"
        exit 1
    fi

    ServerPort=$(jq -r '.server_port // empty' "${JsonFilePath}")
    [ -z "$ServerPort" ] && echo -e "Configuration option 'server_port' acquisition failed" && exit 1
    Password=$(jq -r '.password // empty' "${JsonFilePath}")
    [ -z "$Password" ] && echo -e "Configuration option 'password' acquisition failed" && exit 1
    Method=$(jq -r '.method // empty' "${JsonFilePath}")
    [ -z "$Method" ] && echo -e "Configuration option 'method' acquisition failed" && exit 1
    Mode=$(jq -r '.mode // empty' "${JsonFilePath}")
    [ -z "$Mode" ] && echo -e "Configuration option 'Mode' acquisition failed" && exit 1

    if [[ ${Method} == "aes-128-gcm" ]]; then
        Method="AEAD_AES_128_GCM"
    elif [[ ${Method} == "aes-256-gcm" ]]; then
        Method="AEAD_AES_256_GCM"
    elif [[ ${Method} == "chacha20-ietf-poly1305" ]]; then
        Method="AEAD_CHACHA20_POLY1305"
    fi

    if [[ ${Mode} == "tcp_only" ]]; then
        Mode="-tcp"
    elif [[ ${Mode} == "udp_only" ]]; then
        Mode="-udp"
    elif [[ ${Mode} == "tcp_and_udp" ]]; then
        Mode="-tcp -udp"
    fi

    # Decide once whether a plugin is configured, using jq (the authoritative
    # parser) rather than grepping raw text. do_start / do_stop reuse UsePlugin
    # so every code path agrees on the same answer.
    UsePlugin=0
    Plugin=$(jq -r '.plugin // empty' "${JsonFilePath}")
    PluginOpts=$(jq -r '.plugin_opts // empty' "${JsonFilePath}")

    if [ -n "$Plugin" ] || [ -n "$PluginOpts" ]; then
        # A plugin was requested: both fields are mandatory. Fail loudly here
        # instead of starting half a service with broken plugin arguments.
        if [ -z "$Plugin" ]; then
            echo -e "Configuration option 'plugin' acquisition failed"
            exit 1
        fi
        if [ -z "$PluginOpts" ]; then
            echo -e "Configuration option 'plugin_opts' acquisition failed"
            exit 1
        fi
        UsePlugin=1
    fi
}

check_running() {
    local PidFile=$1

    if [ -e $PidFile ]; then
        if [ -r $PidFile ]; then
            read PID < $PidFile
            if [ -d "/proc/$PID" ]; then
                return 0
            else
                rm -f $PidFile
                return 1
            fi
        fi
    else
        return 2
    fi
}

do_status() {
    check_running "${PID_FILE}"
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
    if check_running "${PID_FILE}"; then
        echo "$NAME (pid $PID) is already running."
        return 0
    fi
    ulimit -n 51200
    if [ "$UsePlugin" = "1" ]; then
        nohup $DAEMON -s "ss://${Method}:${Password}@:${ServerPort}" ${Mode} -verbose -plugin ${Plugin} -plugin-opts "${PluginOpts}" > $LOG 2>&1 &
    else
        nohup $DAEMON -s "ss://${Method}:${Password}@:${ServerPort}" ${Mode} -verbose > $LOG 2>&1 &
    fi
    check_pid "${DAEMON}"
    echo $GET_PID > $PID_FILE
    if check_running "${PID_FILE}"; then
        echo "Starting $NAME success"
    else
        echo "Starting $NAME failed"
        RET_VAL=1
    fi
}

do_stop() {
    if check_running "${PID_FILE}"; then
        kill -9 $PID
        rm -f $PID_FILE
        if [ "$UsePlugin" = "1" ]; then
            check_pid "${Plugin}"
            [ -n "$GET_PID" ] && kill -9 $GET_PID
        fi
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

# Only run the service dispatch when executed directly. When the script is
# sourced (e.g. by the regression test) we expose the functions without
# touching the system or exiting the caller's shell.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    check_pid "${DAEMON}"
    check_pid_file "${GET_PID}" "${PID_FILE}"
    create_pid_dir "${PID_DIR}"
    get_config_args "${CONF}"

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
fi