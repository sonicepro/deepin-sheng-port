#!/bin/bash
# 让 KMRE 容器支持 32 位（armeabi-v7a）应用。
#
# 背景（真机验证，2026-10，sheng 平板 / openKylin 3.0）：
#   上游容器镜像本身是 64/32 位双 ABI 的——
#       ro.odm.product.cpu.abilist32=armeabi-v7a,armeabi
#       ro.zygote=zygote64_32
#       etc/init/hw/init.zygote64_32.rc、init.zygote32.rc
#   但容器起来后 **ro.product.cpu.abilist32 是空的**，zygote 只有 64 位：
#       ro.product.cpu.abilist   = arm64-v8a
#       ro.product.cpu.abilist32 = (空)
#   于是商店/容器认为系统纯 64 位，32 位包（目录里少数几个，如部分老游戏）
#   装不上。product 级 ABI 属性优先级高于 odm/vendor，空值把 32 位屏蔽了。
#
# 做法：kmre manager 的 D-Bus 方法 setSystemProp(0, key, value) 可以把容器属性
# 设回去（实测生效）。注意该接口**不接受空字符串**，所以只能开、不能关；重复设置
# 同一值是幂等的，轮到下一次开机再执行也安全。
#
# 仅设置 ABI 属性，不重启容器、不改镜像、不落任何镜像文件。
set -u

BUS="${KMRE_ABI32_BUS:-unix:path=/run/user/1000/bus}"
DEST="cn.kylinos.Kmre.Manager"
OPATH="/cn/kylinos/Kmre/Manager"
KEY="ro.product.cpu.abilist32"
VALUE="armeabi-v7a,armeabi"

command -v gdbus >/dev/null 2>&1 || { echo "kmre-abi32: 无 gdbus，跳过"; exit 0; }

getprop() {
    timeout 10 gdbus call --address "$BUS" --dest "$DEST" --object-path "$OPATH" \
        --method "$DEST.getSystemProp" 0 "$1" 2>/dev/null |
        sed -n "s/^('\(.*\)',)$/\1/p"
}

# 等到容器把属性服务带起来（daemon 在，但 Android 侧属性要稍后才可用）。
for _ in $(seq 1 60); do
    cur="$(getprop "$KEY")"
    if [ -n "$cur" ]; then
        break
    fi
    sleep 2
done

cur="$(getprop "$KEY")"
if [ "$cur" = "$VALUE" ]; then
    echo "kmre-abi32: 已是 $VALUE（无需处理）"
    exit 0
fi

if timeout 15 gdbus call --address "$BUS" --dest "$DEST" --object-path "$OPATH" \
        --method "$DEST.setSystemProp" 0 "$KEY" "$VALUE" >/dev/null 2>&1; then
    now="$(getprop "$KEY")"
    if [ "$now" = "$VALUE" ]; then
        echo "kmre-abi32: $KEY 已从 '${cur:-（空）}' 设为 $VALUE"
        exit 0
    fi
    echo "kmre-abi32: 设置后回读为 '${now:-（空）}'，未生效" >&2
    exit 1
fi

echo "kmre-abi32: setSystemProp 调用失败（容器可能未就绪）" >&2
exit 1
