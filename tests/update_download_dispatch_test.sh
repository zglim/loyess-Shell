#!/usr/bin/env bash
#
# utils/update.sh 中 update_download() 下载分流逻辑的最小回归测试。
#
# 背景：历史上 update_download() 写成 `if $(judge_is_num "${downloadMark}"); then`，
# 而 judge_is_num 只通过【退出码】表达结果、不向标准输出写任何内容，导致 $(...) 捕获到
# 空字符串后被当成命令执行，数值型插件标记与字符串型核心标记的分流都可能失真。
#
# 本测试至少覆盖三类场景：
#   1. 数字标记   -> 进入插件下载分支（download_plugins_file，且 plugin_num 被正确设置）
#   2. 字符串标记 -> 进入核心下载分支（download_ss_file，且 SS_VERSION 被正确设置）
#   3. 非法/空标记 -> 不进入任何下载分支，明确报错并以非零状态退出
# 另外单独锁定 judge_is_num 的接口约定（纯退出码、标准输出必须为空）。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
UPDATE_SH="${REPO_ROOT}/utils/update.sh"

# 所有被测代码里的 `mktemp -d` 都落到这个受控目录下，测试结束后整体清理。
TEST_TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_TMP_ROOT}"' EXIT

pass_count=0
fail_count=0

ok(){ printf '  [PASS] %s\n' "$1"; pass_count=$((pass_count + 1)); }
ng(){ printf '  [FAIL] %s\n' "$1"; fail_count=$((fail_count + 1)); }

assert_contains(){     # haystack needle desc
    case "$1" in
        *"$2"*) ok "$3" ;;
        *)      ng "$3 (期望包含: '$2'，实际输出: '$1')" ;;
    esac
}

assert_not_contains(){ # haystack needle desc
    case "$1" in
        *"$2"*) ng "$3 (不应包含: '$2'，实际输出: '$1')" ;;
        *)      ok "$3" ;;
    esac
}

assert_rc(){           # actual_rc expected_rc desc
    if [ "$1" -eq "$2" ]; then
        ok "$3"
    else
        ng "$3 (期望退出码: $2，实际: $1)"
    fi
}

assert_rc_nonzero(){   # actual_rc desc
    if [ "$1" -ne 0 ]; then
        ok "$2"
    else
        ng "$2 (期望非零退出码，实际: 0)"
    fi
}

# 在独立 bash 进程里加载桩函数 + 真实 update.sh，再调用 update_download。
# 独立进程能隔离被测函数内部的 exit，并捕获其标准输出/错误与退出码。
# $0=_bash  $1=downloadMark  $2=update.sh 路径
run_case(){
    TMPDIR="${TEST_TMP_ROOT}" bash -c '
        improt_package(){ :; }
        _echo(){ :; }
        download_plugins_file(){ printf "ENTER_PLUGINS plugin_num=[%s]\n" "${plugin_num}"; }
        download_ss_file(){ printf "ENTER_SS SS_VERSION=[%s]\n" "${SS_VERSION}"; }
        source "$2"
        update_download "$1" "test-app"
    ' _bash "$1" "${UPDATE_SH}" 2>&1
}

echo "== 场景一：数字标记进入插件下载 =="
out="$(run_case "5")"; rc=$?
assert_rc "${rc}" 0 "数字标记 '5' 正常返回"
assert_contains "${out}" "ENTER_PLUGINS plugin_num=[5]" "数字标记 '5' 进入插件分支并设置 plugin_num"
assert_not_contains "${out}" "ENTER_SS" "数字标记 '5' 不会串入核心分支"

out="$(run_case "12")"; rc=$?
assert_rc "${rc}" 0 "两位数字标记 '12' 正常返回"
assert_contains "${out}" "ENTER_PLUGINS plugin_num=[12]" "两位数字标记 '12' 进入插件分支并设置 plugin_num"
assert_not_contains "${out}" "ENTER_SS" "两位数字标记 '12' 不会串入核心分支"

echo "== 场景二：字符串标记进入核心下载 =="
for mark in ss-libev ss-rust go-ss2; do
    out="$(run_case "${mark}")"; rc=$?
    assert_rc "${rc}" 0 "核心标记 '${mark}' 正常返回"
    assert_contains "${out}" "ENTER_SS SS_VERSION=[${mark}]" "核心标记 '${mark}' 进入核心分支并设置 SS_VERSION"
    assert_not_contains "${out}" "ENTER_PLUGINS" "核心标记 '${mark}' 不会串入插件分支"
done

echo "== 场景三：非法/空标记不会误走下载流程 =="
for bad in "" "bogus" "1.2" "ss-foo"; do
    label="${bad:-<空字符串>}"
    out="$(run_case "${bad}")"; rc=$?
    assert_rc_nonzero "${rc}" "非法标记 '${label}' 以非零状态退出"
    assert_not_contains "${out}" "ENTER_PLUGINS" "非法标记 '${label}' 不进入插件下载分支"
    assert_not_contains "${out}" "ENTER_SS" "非法标记 '${label}' 不进入核心下载分支"
done

echo "== 附加：锁定 judge_is_num 接口约定（纯退出码 + 标准输出为空）=="
# 在当前进程加载（improt_package 已被桩为 no-op，故不会真去 source downloads.sh）。
improt_package(){ :; }
_echo(){ :; }
# shellcheck source=/dev/null
source "${UPDATE_SH}"

judge_is_num "7";       assert_rc "$?" 0 "judge_is_num 对 '7' 返回 0（是数字）"
judge_is_num "10";      assert_rc "$?" 0 "judge_is_num 对 '10' 返回 0（是数字）"
judge_is_num "ss-rust"; assert_rc "$?" 1 "judge_is_num 对 'ss-rust' 返回 1（非数字）"
judge_is_num "";        assert_rc "$?" 1 "judge_is_num 对空字符串返回 1（非数字）"
judge_is_num "v1";      assert_rc "$?" 1 "judge_is_num 对 'v1' 返回 1（非数字）"

num_out="$(judge_is_num "7")"
if [ -z "${num_out}" ]; then
    ok "judge_is_num 不向标准输出写入内容（这是原 \$(...) 误用的根因）"
else
    ng "judge_is_num 标准输出应为空，实际: '${num_out}'"
fi

echo
echo "== 汇总：通过 ${pass_count}，失败 ${fail_count} =="
[ "${fail_count}" -eq 0 ]
