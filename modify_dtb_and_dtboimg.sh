#!/usr/bin/bash

# These are necessary tools
for f in "mkdtboimg.py" "fdtget" "fdtput" "avbtool"; do
	which $f &>/dev/null || {
		echo "! Error: $f not found!"
		exit 1
	}
done

cd ${0%/*}

for f in "dtb" "dtbo.img"; do
	if ! [ -f "./$f" ]; then
		echo "! Error: ./$f not found!"
		exit 1
	fi
done

###############################################################################
# Prepare
###############################################################################

dtbo_unpack_output=$(mktemp -d)

trap "rm -rf \"$dtbo_unpack_output\"; exit" SIGINT SIGTERM SIGQUIT SIGHUP

cp ./dtbo.img "${dtbo_unpack_output}/dtbo.img"

(
	cd "$dtbo_unpack_output"
	mkdtboimg.py dump ./dtbo.img -b dtbo &>/dev/null
	rm ./dtbo.img
)

# Only keep marble's dtbo
marble_dtbo=
for dtbo_file in "$dtbo_unpack_output"/*; do
	if [ "$(fdtget $dtbo_file / model -ts)" == "Marble based on Qualcomm Technologies, Inc SM7475" ]; then
		marble_dtbo="$dtbo_file"
		break
	fi
done
if [ -z "$marble_dtbo" ]; then
	echo "! Can not found Marble dtbo file!"
	exit 1
fi

###############################################################################
# dtb
###############################################################################

echo "- Patching dtb ..."

# do nothing for now

###############################################################################
# dtbo-0: For MIUI / HyperOS / AOSPA
###############################################################################

cp "$marble_dtbo" ./dtbo-0

do_aw882xx_hack() {
	local dtbo_file=$1
	local node
	local aw882xx_node

	for node in $(fdtget "$dtbo_file" / -l | grep -E 'fragment@[[:digit:]]+'); do
		if fdtget "$dtbo_file" "/${node}/__overlay__" -l | grep -qE 'aw882xx_smartpa@[[:digit:]]+'; then
			aw882xx_node="/${node}/__overlay__"
			break
		fi
	done

	if [ -z "$aw882xx_node" ]; then
		echo "! Can not found aw882xx_smartpa node in ${dtbo_file}!"
		return 1
	fi

	for node in $(fdtget "$dtbo_file" "$aw882xx_node" -l); do
		# Enable fade in/out
		fdtput "$dtbo_file" "${aw882xx_node}/${node}" "fade-flag" 1 -tu

		# Synchronously load the firmware
		fdtput "$dtbo_file" "${aw882xx_node}/${node}" "sync-load" 1 -tu
	done
}

echo "- Patching dtbo-0 ..."

do_aw882xx_hack ./dtbo-0 && sync || exit 1

###############################################################################
# dtbo-1: For rom based on OSS kernel
###############################################################################

cp ./dtbo-0 ./dtbo-1

do_panel_hack() {
	local dtbo_file=$1
	local symbol
	local node

	for symbol in "dsi_m16t_36_02_0a_dsc_vid" "dsi_m16t_36_0d_0b_dsc_vid"; do
		node=$(fdtget "$dtbo_file" "/__symbols__" "$symbol" -ts) || {
			echo "! Can not found ${symbol} node in ${dtbo_file}!"
			return 1
		}

		# Correct physical panel dimensions
		# https://github.com/cupid-development/android_kernel_xiaomi_sm8450-devicetrees/commit/9d5dd22ada720f73713fe44d77153e3189e852e2
		fdtput "$dtbo_file" "${node}" "qcom,mdss-pan-physical-width-dimension"  70  -tu
		fdtput "$dtbo_file" "${node}" "qcom,mdss-pan-physical-height-dimension" 154 -tu

		# Disable 30Hz timing
		# https://github.com/cupid-development/android_kernel_xiaomi_sm8450-devicetrees/commit/b1588abf069a73668643a128b621c738dbd6f9ac
		fdtput "$dtbo_file" "${node}" "qcom,dsi-supported-dfps-list" 60 120 90 -tu

		# Bump minimal brightness to 8
		# https://github.com/cupid-development/android_kernel_xiaomi_sm8450-devicetrees/commit/f0b4ec403959815341a7a77765e90eea82996487
		fdtput "$dtbo_file" "${node}" "qcom,mdss-dsi-bl-min-level" 8 -tu
	done
}

do_xiaomi_touch_hack() {
	local dtbo_file=$1
	local fingerprint_screen_node fingerprint_screen_parent_node fingerprint_screen_panel_val lf_fingerprint_screen_panel_val

	fingerprint_screen_node=$(fdtget "$dtbo_file" /__symbols__ fingerprint_screen -ts)
	fingerprint_screen_parent_node=$(dirname $fingerprint_screen_node)
	fingerprint_screen_panel_val=$(fdtget "$dtbo_file" "$fingerprint_screen_node" panel -tu)
	fdtput "$dtbo_file" -c "${fingerprint_screen_parent_node}/xiaomi-touch"
	fdtput "$dtbo_file" "${fingerprint_screen_parent_node}/xiaomi-touch" "panel-primary" $fingerprint_screen_panel_val -tu

	if fdtget "$dtbo_file" "/__local_fixups__/${fingerprint_screen_node}" -l; then
		lf_fingerprint_screen_panel_val=$(fdtget "$dtbo_file" "/__local_fixups__/${fingerprint_screen_node}" panel -tu)
		fdtput "$dtbo_file" -c "/__local_fixups__${fingerprint_screen_parent_node}/xiaomi-touch"
		fdtput "$dtbo_file" "/__local_fixups__${fingerprint_screen_parent_node}/xiaomi-touch" "panel-primary" $lf_fingerprint_screen_panel_val -tu
	fi
}

echo "- Patching dtbo-1 ..."

do_panel_hack ./dtbo-1 && do_xiaomi_touch_hack ./dtbo-1 && sync || exit 1

###############################################################################
# Make dtbo.img
###############################################################################

for dtbo_file in ./dtbo-0 ./dtbo-1; do
	echo "- Making ${dtbo_file}.img ..."
	mkdtboimg.py create ${dtbo_file}.img $dtbo_file
	avbtool add_hash_footer --partition_name dtbo --partition_size $((24 * 1024 * 1024)) --image ${dtbo_file}.img
	rm $dtbo_file
done

###############################################################################
# Cleanup
###############################################################################

echo "- Cleaning up ..."

rm -rf "$dtbo_unpack_output"

echo "- Done!"
