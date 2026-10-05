#
# Copyright (C) 2013-2018 The Android-x86 Open Source Project
#
# License: GNU Public License v2 or later
#

function set_property()
{
	setprop "$1" "$2"
	[ -n "$DEBUG" ] && echo "$1"="$2" >> /dev/x86.prop
}

function set_prop_if_empty()
{
	[ -z "$(getprop $1)" ] && set_property "$1" "$2"
}

houdini_enable=0                                        
                                         
function switch_houdini()   
{                                                         
	if [ -f "/vendor/bin/houdini" -a -f "/vendor/bin/houdini64" -a -f "/vendor/lib/libhoudini.so" -a -f "/vendor/lib64/libhoudini.so" ]; then
                houdini_enable=1
        fi
}

function init_translation()                             
{                                            
        cat /data/local.prop | grep -q houdini && switch_houdini
        if [ $houdini_enable -eq 0 ];then                       
                cat /data/local.prop | grep -q ro.dalvik.vm.native.bridge && set_prop_if_empty "ro.dalvik.vm.native.bridge" "libndk_translation.so"
                cat /data/local.prop | grep -q ro.dalvik.vm.native.bridge || set_prop_if_empty "ro.dalvik.vm.native.bridge" "0"                    
        fi                                                                                                                                         
                                                                                                                                                   
        local translator=$(getprop ro.dalvik.vm.native.bridge)                                                                                     
        if [ "$translator" = "libhoudini.so" ]; then                                                                                               
                mount --bind   /system/vendor/bin/arm      /system/bin/arm                                                                         
                mount --bind   /system/vendor/bin/arm64    /system/bin/arm64                                                                       
                mount --bind   /system/vendor/lib/arm      /system/lib/arm                                                                         
                mount --bind   /system/vendor/lib64/arm64  /system/lib64/arm64                                                                     
        elif [ "$translator" = "libndk_translation.so" ]; then                                                                                     
                mount --bind   /system/bin/arm      /system/vendor/bin/arm                                                                         
                mount --bind   /system/bin/arm64    /system/vendor/bin/arm64                                                                       
                mount --bind   /system/lib/arm      /system/vendor/lib/arm                                                                         
                mount --bind   /system/lib64/arm64  /system/vendor/lib64/arm64                                                                     
        else                                                                                                                                       
                cat /data/local.prop | grep -q ro.dalvik.vm.native.bridge || set_prop_if_empty "ro.dalvik.vm.native.bridge" "0"                    
        fi                                                                                                                                         
}

function init_misc()
{
	if [ ! -d "/data/local/tmp" ];then
		rm -rf /data/local/tmp
		mkdir /data/local/tmp
		chown 2000.2000 /data/local/tmp
		chmod 0777 /data/local/tmp
	else
		echo "dir is exists"
	fi
    rm -rf /data/local/tmp/*.apk
	cat /data/local.prop | grep -q 'qemu.sf.lcd_density'
	if [ $? = "0" ]; then
		local density=$(cat /data/local.prop | grep qemu.sf.lcd_density | awk -F= '{print $2}')
		set_prop_if_empty "qemu.sf.lcd_density" "$density"
	fi

	echo 65535 > /proc/sys/kernel/pid_max
	# device information
	set_property ro.product.manufacturer "$(cat $DMIPATH/sys_vendor)"
	set_property ro.product.model "$PRODUCT"
	set_property ro.kmre.device "Kmre2 $(cat $DMIPATH/sys_vendor) $PRODUCT"
    # enable sdcardfs if /data is not mounted on tmpfs or 9p
    mount | grep /data\ | grep -qE 'tmpfs|9p'
    [ $? -eq 0 ] && set_prop_if_empty external_storage.sdcardfs.enabled false

    # enable virt_wifi if needed
    local eth=$(getprop persist.kmre.network.device eth0)
    local mode=$(getprop sys.kmre.network.mode bridge)
    if [ -d /sys/class/net/wlan0 ]; then
        ip link del wlan0
    fi
    if [ "$mode" = "bridge" ]; then
        ifconfig $eth up
    elif [ "$mode" = "host" ]; then
        ip link add link $eth name wlan0 type virt_wifi
    fi
	
    if [ ! -e /dev/tun ]; then
        local tun_major=$(getprop sys.tun.device.major)
        local tun_minor=$(getprop sys.tun.device.minor)
        if [ "$tun_major" != "" -a "$tun_major" != "0" -a "$tun_minor" != "" -a "$tun_minor" != "0" ]; then
            /system/bin/mknod /dev/tun c $tun_major $tun_minor
            /system/bin/chmod 0660 /dev/tun
            /system/bin/chown system.vpn /dev/tun
        fi
    fi

}

function init_platform()
{
	cat /proc/cpuinfo | egrep -iq 'FT2000|FT-2000'
	if [ "$?" = 0 ]; then
		setprop ro.on_platform_ft2000plus "1"
		setprop ro.cpu_platform_name "FT2000A"
		setprop ro.board.platform "FT2000A"
	fi

	cat /proc/cpuinfo | egrep -iq 'FT1500|FT-1500'
	if [ "$?" = 0 ]; then
		setprop ro.on_platform_ft1500a "1"
		setprop ro.cpu_platform_name "FT1500A"
		setprop ro.board.platform "FT1500A"
	fi

	cat /proc/cpuinfo | grep -iq 'KUNPENG'
	if [ "$?" = 0 ]; then
		setprop ro.on_platform_kunpeng "1"
		setprop ro.cpu_platform_name "KUNPENG"
		setprop ro.board.platform "KUNPENG"
	fi

	cat /proc/cpuinfo | grep -iq 'Kirin.*990'
	if [ "$?" = 0 ]; then
		setprop ro.board.platform "Kirin 990"
	fi

	cat /proc/cpuinfo | grep -iq 'Phytium.*D2000'
	if [ "$?" = 0 ]; then
		setprop ro.board.platform "Phytium D2000"
	fi

	cat /proc/cpuinfo | grep -iq 'Kirin.*9006C'
	if [ "$?" = 0 ]; then
		setprop ro.board.platform "Kirin 9006C"
	fi

	cat /proc/cpuinfo | grep -iq 'ZHAOXIN'
	if [ "$?" = 0 ]; then
		setprop ro.board.platform "ZHAOXIN"
	fi

	cat /proc/cpuinfo | grep -iq 'Hygon'
	if [ "$?" = 0 ]; then
		setprop ro.board.platform "Hygon"
	fi

	cat /proc/cpuinfo | grep -iq 'PANGU.*M900'
	if [ "$?" = 0 ]; then
		setprop ro.board.platform "PANGU M900"
	fi
}

function init_hal_audio()
{
	set_property ro.hardware.audio.primary kmre
}
function init_hal_sensors_kmre()
{
   set_property ro.hardware.sensors kmre
}
function init_hal_bluetooth()
{
}

function init_hal_camera()
{
	set_property ro.hardware.camera kmre
}

function init_hal_gps_kmre()
 {
    set_property ro.hardware.gps kmre
 }

function set_drm_mode()
{
}

function init_uvesafb()
{
}

function init_hal_gralloc()
{

}

function init_hal_hwcomposer()
{
	# TODO
	return
}

function init_hal_vulkan()
{
	local egl_prop=$(getprop ro.hardware.egl)
	local gralloc_prop=$(getprop ro.hardware.gralloc)
	if [ "$egl_prop" = "mesa" ]; then
		if [ "$gralloc_prop" = "intel" ] || [ "$gralloc_prop" = "gbm" ]; then
			case "$(cat /proc/fb | head -1)" in
				0*i915drmfb|0*inteldrmfb)
					set_property ro.hardware.vulkan intel
					;;
				0*amdgpudrmfb)
					set_property ro.hardware.vulkan radv
					;;
				*)
					;;
			esac
		fi
	fi
}

function init_hal_lights()
{
	chown 1000.1000 /sys/class/backlight/*/brightness
    echo 100 > /data/brightness_file
    echo 255 > /data/max_brightness_file
    chown 1000.1000 /data/brightness_file
    chown 1000.1000 /data/max_brightness_file
}

function init_hal_suspend()
{
    mkdir /data/power
    mount | grep -q "/sys/power" && return || echo
	
    #don't cp /sys/power/* on Kirin990 may block
    #cp /sys/power/* /data/power	
    touch /data/power/disk
    touch /data/power/image_size
    touch /data/power/mem_sleep
    touch /data/power/pm_async
    touch /data/power/pm_debug_messages
    touch /data/power/pm_freeze_timeout
    touch /data/power/pm_print_times
    touch /data/power/pm_test
    touch /data/power/pm_wakeup_irq
    touch /data/power/reserved_size
    touch /data/power/resume
    touch /data/power/resume_offset
    touch /data/power/state
    touch /data/power/suspend_stats
    touch /data/power/wake_lock
    touch /data/power/wake_unlock
    touch /data/power/wakeup_count	
	
    mount | grep -q /sys/power && echo 1 || mount -o bind /data/power /sys/power
	
    /system/bin/chown system:system /sys/power/state
    /system/bin/chown system:system /sys/power/wakeup_count
    /system/bin/chmod 0660 /sys/power/state
    /system/bin/chown system:system /sys/power/autosleep
    /system/bin/chown radio:wakelock /sys/power/wake_lock
    /system/bin/chown radio:wakelock /sys/power/wake_unlock
    /system/bin/chmod 0660 /sys/power/wake_lock
    /system/bin/chmod 0660 /sys/power/wake_unlock
}

function init_hal_power()
{
	# TODO
	case "$PRODUCT" in
		HP*Omni*|OEMB|Standard*PC*|Surface*3|T10*TA|VMware*)
			set_prop_if_empty sleep.state none
			;;
		*)
			;;
	esac
}

function init_hal_sensors()
{
	# if we have sensor module for our hardware, use it
	ro_hardware=$(getprop ro.hardware)
	[ -f /system/lib/hw/sensors.${ro_hardware}.so ] && return 0

	local hal_sensors=kbd
	local has_sensors=true
	case "$(cat $DMIPATH/uevent)" in
		*Lucid-MWE*)
			set_property ro.ignore_atkbd 1
			hal_sensors=hdaps
			;;
		*ICONIA*W5*)
			hal_sensors=w500
			;;
		*S10-3t*)
			hal_sensors=s103t
			;;
		*Inagua*)
			#setkeycodes 0x62 29
			#setkeycodes 0x74 56
			set_property ro.ignore_atkbd 1
			set_property hal.sensors.kbd.type 2
			;;
		*TEGA*|*2010:svnIntel:*)
			set_property ro.ignore_atkbd 1
			set_property hal.sensors.kbd.type 1
			io_switch 0x0 0x1
			setkeycodes 0x6d 125
			;;
		*DLI*)
			set_property ro.ignore_atkbd 1
			set_property hal.sensors.kbd.type 1
			setkeycodes 0x64 1
			setkeycodes 0x65 172
			setkeycodes 0x66 120
			setkeycodes 0x67 116
			setkeycodes 0x68 114
			setkeycodes 0x69 115
			setkeycodes 0x6c 114
			setkeycodes 0x6d 115
			;;
		*tx2*)
			setkeycodes 0xb1 138
			setkeycodes 0x8a 152
			set_property hal.sensors.kbd.type 6
			set_property poweroff.doubleclick 0
			set_property qemu.hw.mainkeys 1
			;;
		*MS-N0E1*)
			set_property ro.ignore_atkbd 1
			set_property poweroff.doubleclick 0
			setkeycodes 0xa5 125
			setkeycodes 0xa7 1
			setkeycodes 0xe3 142
			;;
		*Aspire1*25*)
			modprobe lis3lv02d_i2c
			echo -n "enabled" > /sys/class/thermal/thermal_zone0/mode
			;;
		*ThinkPad*Tablet*)
			modprobe hdaps
			hal_sensors=hdaps
			;;
		*LINX1010B*)
			set_property ro.iio.accel.z.opt_scale -1
			;&
		*i7Stylus*|*M80TA*)
			set_property ro.iio.accel.x.opt_scale -1
			;;
		*LenovoMIIX320*|*ONDATablet*)
			set_property ro.iio.accel.order 102
			set_property ro.iio.accel.x.opt_scale -1
			set_property ro.iio.accel.y.opt_scale -1
			;;
		*Venue*8*Pro*3845*)
			set_property ro.iio.accel.order 102
			;;
		*SP111-33*)
			set_property ro.iio.accel.quirks no-trig
			;&
		*ST70416-6*)
			set_property ro.iio.accel.order 102
			;;
		*e-tabPro*|*pnEZpad*)
			set_property ro.iio.accel.quirks no-trig
			;&
		*T*0*TA*)
			set_property ro.iio.accel.y.opt_scale -1
			;;
		*)
			has_sensors=false
			;;
	esac

	# has iio sensor-hub?
	if [ -n "`ls /sys/bus/iio/devices/iio:device* 2> /dev/null`" ]; then
		busybox chown -R 1000.1000 /sys/bus/iio/devices/iio:device*/
		[ -n "`ls /sys/bus/iio/devices/iio:device*/in_accel_x_raw 2> /dev/null`" ] && has_sensors=true
		hal_sensors=iio
	elif lsmod | grep -q lis3lv02d_i2c; then
		hal_sensors=hdaps
		has_sensors=true
	elif [ "$hal_sensors" != "kbd" ]; then
		has_sensors=true
	fi

	set_property ro.hardware.sensors $hal_sensors
	set_property config.override_forced_orient ${HAS_SENSORS:-$has_sensors}
}

function create_pointercal()
{
	if [ ! -e /data/misc/tscal/pointercal ]; then
		mkdir -p /data/misc/tscal
		touch /data/misc/tscal/pointercal
		chown 1000.1000 /data/misc/tscal /data/misc/tscal/*
		chmod 775 /data/misc/tscal
		chmod 664 /data/misc/tscal/pointercal
	fi
}

function init_tscal()
{
	case "$PRODUCT" in
		ST70416-6*)
			modprobe gslx680_ts_acpi
			;&
		T91|T101|ET2002|74499FU|945GSE-ITE8712|CF-19[CDYFGKLP]*)
			create_pointercal
			return
			;;
		*)
			;;
	esac

	for usbts in $(lsusb | awk '{ print $6 }'); do
		case "$usbts" in
			0596:0001|0eef:0001)
				create_pointercal
				return
				;;
			*)
				;;
		esac
	done
}

function init_ril()
{
	case "$(cat $DMIPATH/uevent)" in
		*TEGA*|*2010:svnIntel:*|*Lucid-MWE*)
			set_property rild.libpath /system/lib/libhuaweigeneric-ril.so
			set_property rild.libargs "-d /dev/ttyUSB2 -v /dev/ttyUSB1"
			set_property ro.radio.noril no
			;;
		*)
			set_property ro.radio.noril yes
			;;
	esac
}

function init_cpu_governor()
{
}

function do_init()
{
	init_translation
	init_misc
	init_platform
	init_hal_audio
	init_hal_bluetooth
	init_hal_camera
	init_hal_gralloc
	init_hal_hwcomposer
	init_hal_vulkan
	init_hal_lights
    init_hal_suspend
	init_hal_power
    init_hal_sensors_kmre
    init_hal_gps_kmre
	init_tscal
	init_ril
	post_init
}

function do_netconsole()
{
}

function do_bootcomplete()
{
	hciconfig | grep -q hci || pm disable com.android.bluetooth

	init_cpu_governor

	[ -z "$(getprop persist.sys.root_access)" ] && setprop persist.sys.root_access 3

	lsmod | grep -Ehq "brcmfmac|rtl8723be" && setprop wlan.no-unload-driver 1

	case "$PRODUCT" in
		1866???|1867???|1869???) # ThinkPad X41 Tablet
			start tablet-mode
			start wacom-input
			setkeycodes 0x6d 115
			setkeycodes 0x6e 114
			setkeycodes 0x69 28
			setkeycodes 0x6b 158
			setkeycodes 0x68 172
			setkeycodes 0x6c 127
			setkeycodes 0x67 217
			;;
		6363???|6364???|6366???) # ThinkPad X60 Tablet
			;&
		7762???|7763???|7767???) # ThinkPad X61 Tablet
			start tablet-mode
			start wacom-input
			setkeycodes 0x6d 115
			setkeycodes 0x6e 114
			setkeycodes 0x69 28
			setkeycodes 0x6b 158
			setkeycodes 0x68 172
			setkeycodes 0x6c 127
			setkeycodes 0x67 217
			;;
		7448???|7449???|7450???|7453???) # ThinkPad X200 Tablet
			start tablet-mode
			start wacom-input
			setkeycodes 0xe012 158
			setkeycodes 0x66 172
			setkeycodes 0x6b 127
			;;
		Surface*Go)
			echo on > /sys/devices/pci0000:00/0000:00:15.1/i2c_designware.1/power/control
			;;
		VMware*)
			pm disable com.android.bluetooth
			;;
		X80*Power)
			set_property power.nonboot-cpu-off 1
			;;
		*)
			;;
	esac

#	[ -d /proc/asound/card0 ] || modprobe snd-dummy
	for c in $(grep '\[.*\]' /proc/asound/cards | awk '{print $1}'); do
		f=/system/etc/alsa/$(cat /proc/asound/card$c/id).state
		if [ -e $f ]; then
			alsa_ctl -f $f restore $c
		else
			alsa_ctl init $c
			alsa_amixer -c $c set Master on
			alsa_amixer -c $c set Master 100%
			alsa_amixer -c $c set Headphone on
			alsa_amixer -c $c set Headphone 100%
			alsa_amixer -c $c set Speaker 100%
			alsa_amixer -c $c set Capture 80%
			alsa_amixer -c $c set Capture cap
			alsa_amixer -c $c set PCM 100 unmute
			alsa_amixer -c $c set SPO unmute
			alsa_amixer -c $c set IEC958 on
			alsa_amixer -c $c set 'Mic Boost' 1
			alsa_amixer -c $c set 'Internal Mic Boost' 1
		fi
	done

	ENABLED_INPUT_METHODS=$(settings get secure enabled_input_methods)
	DEFAULT_INPUT_METHOD=$(settings get secure default_input_method)
	if [[ "$ENABLED_INPUT_METHODS" = "" ]] || [[ "$ENABLED_INPUT_METHODS" = "null" ]]; then
		settings put secure enabled_input_methods cn.kylinos.kmre.inputmethod/.service.ImeService
		settings put secure default_input_method cn.kylinos.kmre.inputmethod/.service.ImeService
	else
		echo $ENABLED_INPUT_METHODS | grep -q cn.kylinos.kmre.inputmethod/.service.ImeService || settings put secure enabled_input_methods "${ENABLED_INPUT_METHODS}:cn.kylinos.kmre.inputmethod/.service.ImeService"
		if [[ "$DEFAULT_INPUT_METHOD" = "" ]] || [[ "$DEFAULT_INPUT_METHOD" = "null" ]]; then
			settings put secure default_input_method cn.kylinos.kmre.inputmethod/.service.ImeService
		fi
	fi


	# Remove copied files
	/system/bin/rm -f /data/media/0/share_data/*

	post_bootcomplete
}

PATH=/sbin:/system/bin:/system/xbin

DMIPATH=/sys/class/dmi/id
BOARD=$(cat $DMIPATH/board_name)
PRODUCT=$(cat $DMIPATH/product_name)

# import the vendor specific script
hw_sh=/vendor/etc/init.sh
[ -e $hw_sh ] && source $hw_sh

case "$1" in
	netconsole)
		[ -n "$DEBUG" ] && do_netconsole
		;;
	bootcomplete)
		do_bootcomplete
		;;
	init|"")
		do_init
		;;
esac

return 0
