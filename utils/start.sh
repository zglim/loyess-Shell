_check_running() {
    local PID_FILE=$1
    
    if [ ! -e $PID_FILE ]; then
        return 2
    fi
    
    read PID < $PID_FILE
    if [ -z "$PID" ]; then
        return 2
    fi

    if [ -d "/proc/$PID" ]; then
        return 0
    else
        rm -f $PID_FILE
        return 1
    fi
}

sip003_plugin_start(){
    local NAME=$1
    local PLUGIN_PID=$2
    local PID_DIR=/var/run
    local PID_FILE=$PID_DIR/$NAME.pid

    # PidFile exists. PID does not exist. delete PidFile
    if [ -z ${PLUGIN_PID} ]; then
        if [ -e ${PID_FILE} ]; then
            rm -f ${PID_FILE}
        fi
    fi

    # Create PidDir
    if [ ! -d ${PID_DIR} ]; then
        mkdir -p ${PID_DIR}
        if [ $? -ne 0 ]; then
            echo "Creating PID directory $PID_DIR failed"
            exit 1
        fi
    fi

    # Check already running
    if _check_running ${PID_FILE}; then
        echo "$NAME (pid $PID) is already running."
        return 0
    fi

    # Save PID into PidFile
    echo ${PLUGIN_PID} > ${PID_FILE}

    # Check starting
    if _check_running ${PID_FILE}; then
        echo "Starting $NAME success"
    else
        echo "Starting $NAME failed"
    fi
}

initd_file_start(){
    local binaryName=$1
    local initdFilePath=$2
    
    if [ "$(command -v "${binaryName}")" ]; then
        ${initdFilePath} start
    fi
}

sip003_way_start(){
    local binaryName=$1
    local projectName=$2
    local processPid

    if [ "$(command -v "${binaryName}")" ]; then
        processPid=`ps -ef | grep -Ev 'grep|-plugin-opts' | grep "${binaryName}" | awk '{print $2}'`
        sip003_plugin_start "${projectName}" "${processPid}"
    fi
}

nginx_start(){
    # nginx is only managed when the web masquerade mark is present.
    if [ ! -e "${WEB_INSTALL_MARK}" ]; then
        return 0
    fi

    # caddy takes precedence as the web server (see the web server selection in
    # ss-plugins.sh). When caddy is installed nginx is not the active web
    # service, so there is nothing for this function to do here.
    if [ -e "${CADDY_BIN_PATH}" ]; then
        return 0
    fi

    # Web masquerade is enabled and nginx is the expected web server, but its
    # binary is missing. Report a clear failure instead of silently passing.
    if [ ! -e "${NGINX_BIN_PATH}" ]; then
        echo "Starting nginx failed: nginx binary not found at ${NGINX_BIN_PATH}"
        return 1
    fi

    # nginx is driven through systemd; without systemctl it cannot be managed.
    if ! command -v systemctl > /dev/null 2>&1; then
        echo "Starting nginx failed: systemctl is not available"
        return 1
    fi

    # Already running: report it and treat as success.
    if systemctl is-active nginx 2>/dev/null | head -n 1 | grep -qE '^active$'; then
        echo "nginx is already running"
        return 0
    fi

    systemctl start nginx

    # Trust the real service state rather than the exit code of the start call.
    if systemctl is-active nginx 2>/dev/null | head -n 1 | grep -qE '^active$'; then
        echo "Starting nginx success"
        return 0
    fi

    echo "Starting nginx failed"
    return 1
}

start_services(){
    initd_file_start "ss-server" "${SHADOWSOCKS_LIBEV_INIT}"
    initd_file_start "ssservice" "${SHADOWSOCKS_RUST_INIT}"
    initd_file_start "go-shadowsocks2" "${GO_SHADOWSOCKS2_INIT}"
    initd_file_start "kcptun-server" "${KCPTUN_INIT}"
    initd_file_start "ck-server" "${CLOAK_INIT}"
    initd_file_start "rabbit-tcp" "${RABBIT_INIT}"
    if [ -e "${WEB_INSTALL_MARK}" ]; then
        initd_file_start "caddy" "${CADDY_INIT}"
    fi
    sip003_way_start "v2ray-plugin" "v2ray-plugin"
    sip003_way_start "obfs-server" "simple-obfs"
    sip003_way_start "gq-server" "GoQuiet"
    sip003_way_start "mtt-server" "mos-tls-tunnel"
    sip003_way_start "simple-tls" "simple-tls"
    sip003_way_start "gost-plugin" "gost-plugin"
    sip003_way_start "xray-plugin" "xray-plugin"
    sip003_way_start "qtun-server" "qtun"
    sip003_way_start "gun-server" "gun"
    nginx_start
}





