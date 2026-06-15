#!/bin/bash
# 回归测试：验证 judge_is_num + update_download 分支逻辑

PASS=0
FAIL=0
pass() { ((PASS++)); echo "  PASS: $1"; }
fail() { ((FAIL++)); echo "  FAIL: $1"; }

# ---------- 加载被测函数（隔离依赖） ----------
# 桩函数
_echo()   { shift; echo "$@"; }
download_plugins_file() { __CALLED=plugins; }
download_ss_file()      { __CALLED=ss; }
TEMP_DIR_PATH=""

# 只 source judge_is_num 和 update_download
# 从文件中提取这两个函数定义
eval "$(sed -n '/^judge_is_num()/,/^}/p' "$(dirname "$0")/../utils/update.sh")"
eval "$(sed -n '/^update_download()/,/^}/p' "$(dirname "$0")/../utils/update.sh")"

# ---------- judge_is_num 单元 ----------
echo "[judge_is_num]"

judge_is_num "123";   [ $? -eq 0 ] && pass "数字 123 返回0" || fail "数字 123 应返回0"
judge_is_num "0";     [ $? -eq 0 ] && pass "数字 0 返回0"   || fail "数字 0 应返回0"
judge_is_num "";      [ $? -ne 0 ] && pass "空串 返回1"    || fail "空串 应返回1"
judge_is_num "abc";   [ $? -ne 0 ] && pass "字符串 返回1"  || fail "字符串 应返回1"
judge_is_num "ss-libev"; [ $? -ne 0 ] && pass "ss-libev 返回1" || fail "ss-libev 应返回1"
judge_is_num "1.5";   [ $? -ne 0 ] && pass "浮点 返回1"   || fail "浮点 应返回1"

# ---------- update_download 分支集成 ----------
echo ""
echo "[update_download branches]"

# 场景1：数字标记 -> 插件下载
__CALLED=""
update_download "3" "simple-obfs" 2>/dev/null
[ "${__CALLED}" = "plugins" ] && pass "数字标记走插件下载" || fail "数字标记应走插件下载(实际:${__CALLED})"
# TEMP_DIR_PATH 在下载成功后保留（供后续 update_install 使用），由 trap 或显式清理
[ -n "${TEMP_DIR_PATH}" ] && pass "数字标记下载后 TEMP_DIR_PATH 已设置" || fail "TEMP_DIR_PATH 应被设置"

# 场景2：ss-libev 字符串标记 -> 核心下载
__CALLED=""
update_download "ss-libev" "shadowsocks-libev" 2>/dev/null
[ "${__CALLED}" = "ss" ] && pass "ss-libev 走核心下载" || fail "ss-libev 应走核心下载(实际:${__CALLED})"

# 场景3：ss-rust 字符串标记 -> 核心下载
__CALLED=""
update_download "ss-rust" "shadowsocks-rust" 2>/dev/null
[ "${__CALLED}" = "ss" ] && pass "ss-rust 走核心下载" || fail "ss-rust 应走核心下载(实际:${__CALLED})"

# 场景4：go-ss2 字符串标记 -> 核心下载
__CALLED=""
update_download "go-ss2" "go-shadowsocks2" 2>/dev/null
[ "${__CALLED}" = "ss" ] && pass "go-ss2 走核心下载" || fail "go-ss2 应走核心下载(实际:${__CALLED})"

# 场景5：非法标记 -> 不进入任何下载，退出码非0
__CALLED=""
(update_download "garbage" "unknown-app" 2>/dev/null)
EXIT_CODE=$?
[ ${EXIT_CODE} -ne 0 ] && pass "非法标记退出码非0" || fail "非法标记应退出非0(实际:${EXIT_CODE})"
[ -z "${__CALLED}" ] && pass "非法标记未触发任何下载" || fail "非法标记不应触发下载(实际:${__CALLED})"

# 场景6：空标记 -> 不进入任何下载，退出码非0
__CALLED=""
(update_download "" "unknown-app" 2>/dev/null)
EXIT_CODE=$?
[ ${EXIT_CODE} -ne 0 ] && pass "空标记退出码非0" || fail "空标记应退出非0(实际:${EXIT_CODE})"
[ -z "${__CALLED}" ] && pass "空标记未触发任何下载" || fail "空标记不应触发下载(实际:${__CALLED})"

echo ""
echo "结果: ${PASS} passed, ${FAIL} failed"
[ ${FAIL} -eq 0 ] && exit 0 || exit 1
