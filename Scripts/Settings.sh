#!/bin/bash

apply_sed_to_matches() {
	local SEARCH_DIR=$1
	local FILE_NAME=$2
	local SED_EXPR=$3
	local MATCHES

	MATCHES=$(find "$SEARCH_DIR" -type f -name "$FILE_NAME" 2>/dev/null)
	if [ -n "$MATCHES" ]; then
		while IFS= read -r TARGET_FILE; do
			sed -i "$SED_EXPR" "$TARGET_FILE"
		done <<< "$MATCHES"
	fi
}


function cat_kernel_config() {
  if [ -f $1 ]; then
    cat >> $1 <<EOF
CONFIG_BPF=y
CONFIG_BPF_SYSCALL=y
CONFIG_BPF_JIT=y
CONFIG_CGROUPS=y
CONFIG_KPROBES=y
CONFIG_NET_INGRESS=y
CONFIG_NET_EGRESS=y
CONFIG_NET_SCH_INGRESS=m
CONFIG_NET_CLS_BPF=m
CONFIG_NET_CLS_ACT=y
CONFIG_BPF_STREAM_PARSER=y
CONFIG_DEBUG_INFO=y
# CONFIG_DEBUG_INFO_REDUCED is not set
CONFIG_DEBUG_INFO_BTF=y
CONFIG_KPROBE_EVENTS=y
CONFIG_BPF_EVENTS=y

CONFIG_NET_SCH_BPF=y
CONFIG_SCHED_CLASS_EXT=y
CONFIG_PROBE_EVENTS_BTF_ARGS=y
CONFIG_IMX_SCMI_MISC_DRV=n
CONFIG_ARM64_CONTPTE=y

CONFIG_PERSISTENT_HUGE_ZERO_FOLIO=n
CONFIG_NO_PAGE_MAPCOUNT=n
CONFIG_ARM64_BRBE=y
EOF
    echo "cat_kernel_config to $1 done"
  fi
}

# 将 ipq60xx 相关设备的内核分区从 6144k/8192k 升到 12288k
# 之所以要在 emmc-common / nand-common / 多个具体设备块都改一遍，是因为
# 上游可能把 KERNEL_SIZE 写在公共块里（设备靠继承拿到），也可能写在设备自身。
# 为了"无论上游怎么放都能命中"采用穷举式 sed；空白宽松匹配，大小值严格匹配（仅升不降）。
set_kernel_size() {
	local IMAGE_FILE='./target/linux/qualcommax/image/ipq60xx.mk'
	[ -f "$IMAGE_FILE" ] || { echo "set_kernel_size: $IMAGE_FILE not found, skip"; return 0; }

	local SP='[[:space:]]*'

	# emmc-common 公共块：6144k -> 12288k
	sed -i -E "/^define Device\/emmc-common/,/^endef/ s/KERNEL_SIZE${SP}:=${SP}6144k/KERNEL_SIZE := 12288k/" "$IMAGE_FILE"

	# nand-common 公共块：仅在还没有 KERNEL_SIZE 时才注入 8192k（幂等）
	if ! awk '/^define Device\/nand-common/,/^endef/' "$IMAGE_FILE" | grep -Eq "KERNEL_SIZE${SP}:="; then
		sed -i -E "/^define Device\/nand-common/,/^endef/ s/^endef/\tKERNEL_SIZE := 8192k\nendef/" "$IMAGE_FILE"
	fi

	# 具体设备块：6144k -> 12288k
	local DEV
	for DEV in jdcloud_re-ss-01 jdcloud_re-cs-02 jdcloud_re-cs-07; do
		sed -i -E "/^define Device\/${DEV}/,/^endef/ s/KERNEL_SIZE${SP}:=${SP}6144k/KERNEL_SIZE := 12288k/" "$IMAGE_FILE"
	done

	# linksys_mr* 设备块（含 linksys_mr7350 / linksys_mr7500 子块）：8192k -> 12288k
	sed -i -E "/^define Device\/linksys_mr/,/^endef/ s/KERNEL_SIZE${SP}:=${SP}8192k/KERNEL_SIZE := 12288k/" "$IMAGE_FILE"

	# 校验：文件中至少要存在一处 12288k（无论是这次改的还是之前已有的）
	if grep -Eq "KERNEL_SIZE${SP}:=${SP}12288k" "$IMAGE_FILE"; then
		echo "set_kernel_size: ipq60xx kernel partitions ensured at 12288k"
	else
		echo "set_kernel_size: WARNING - 12288k not present after sed; upstream format may have changed" >&2
	fi
}

#移除luci-app-attendedsysupgrade
apply_sed_to_matches "./feeds/luci/collections/" "Makefile" "/attendedsysupgrade/d"

#修改默认主题
#sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#sed -i "s/luci-theme-.*$/luci-theme-bootstrap/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")

#修改immortalwrt.lan关联IP
apply_sed_to_matches "./feeds/luci/modules/luci-mod-system/" "flash.js" "s/192\\.168\\.[0-9]*\\.[0-9]*/$WRT_IP/g"
#添加编译日期标识
apply_sed_to_matches "./feeds/luci/modules/luci-mod-status/" "10_system.js" "s/(\\(luciversion || ''\\))/(\\1) + (' \\/ $WRT_MARK-$WRT_DATE')/g"

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	#修改WIFI名称
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" "$WIFI_SH"
	#修改WIFI密码
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" "$WIFI_SH"
elif [ -f "$WIFI_UC" ]; then
	#修改WIFI名称
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	#修改WIFI密码
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
	#修改WIFI地区
	sed -i "s/country='.*'/country='US'/g" $WIFI_UC
	#修改WIFI加密
	sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" "$CFG_FILE"
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" "$CFG_FILE"

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
#echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
#echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#高通平台调整
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	#取消nss相关feed
	echo "CONFIG_FEED_nss_packages=n" >> ./.config
	echo "CONFIG_FEED_sqm_scripts_nss=n" >> ./.config
	#设置NSS版本
	echo "CONFIG_NSS_FIRMWARE_VERSION_11_4=n" >> ./.config
	echo "CONFIG_NSS_FIRMWARE_VERSION_12_5=y" >> ./.config
	#无WIFI配置调整Q6大小
	if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
		find "$DTS_PATH" -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "qualcommax set up nowifi successfully!"
	fi

fi

# =========================================================
# 智能系统调优：优化内存水位线 (min_free_kbytes)
# =========================================================

MIN_FREE_VAL=8192
CONF_FILE="./package/base-files/files/etc/sysctl.conf"

# 提取当前值（只匹配非注释、行首）
CURRENT_VAL=$(sed -n 's/^vm\.min_free_kbytes=\([0-9]\+\).*/\1/p' "$CONF_FILE")

if [ -z "$CURRENT_VAL" ]; then
    echo "" >> "$CONF_FILE"
    echo "vm.min_free_kbytes=$MIN_FREE_VAL" >> "$CONF_FILE"
    echo "Memory patch: value not found, added $MIN_FREE_VAL."
else
    if [ "$CURRENT_VAL" -lt "$MIN_FREE_VAL" ]; then
        sed -i "s/^vm\.min_free_kbytes=.*/vm.min_free_kbytes=$MIN_FREE_VAL/" "$CONF_FILE"
        echo "Memory patch: upgraded $CURRENT_VAL -> $MIN_FREE_VAL."
    else
        echo "Memory patch: current value ($CURRENT_VAL) is sufficient, skipped."
    fi
fi

#调整 ipq60xx 设备内核分区到 12M
if [[ "${WRT_CONFIG^^}" == *"IPQ60XX"* ]]; then
        set_kernel_size
fi

## copy from function
# local target=ipq60xx
cat_kernel_config "target/linux/qualcommax/ipq60xx/config-default"