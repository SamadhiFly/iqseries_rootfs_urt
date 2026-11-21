#!/bin/sh
# platform-specific init fuctions (SIDU platform).

# Arguments to pass to the 'pidof' command. (-x is not supported in SIDU.)
readonly PIDOF_ARGS=""

# Is the watchdog timer enabled?
do_watchdog_check()
{
	# In SIDU, the watchdog is not accessible through init scripts, but only through sysmngr.
	# (see idsapps/realtime/Source/Drivers/Timer/CatnissWatchdogTimer.cpp)
	# value '1' corresponds to 'watchdog is disabled'. 
	return 1
}

# Stop the watchdog timer.
do_watchdog_stop()
{
	return 0
}

# Start the watchdog timer.
do_watchdog_start()
{
	return 0
}

# Load the firmware (FPGA images, or equivalent) and drivers for this remote.
# return 0 on success.
# for SIDU, this means:
# 1. Loading driver modules (i.e. atdma_buffers).
# 2. Loading the CEVA DSP images, through the BigPig program (which is a one-shot
# run, process does not persist).
# 3. Initializing modem, through the Tweety program (one-shot run as well).
#
# As far as we have tested, these 3 activities must be done once (AND ONLY once),
# on system startup, before the remote processes (i.e. Griffin, Sabine) start.
# This limitation is considered here to support alternate calls to 'service urt stop'/
# 'start'. In fact, the 'unload' calls will not unload them, and the subsequent 'load'
# will have no effect.
# Note: Bad results (such as CEVA demod lockup, or complete board lockup) were
# experienced when these 3 activities were executed otherwise, i.e. when
# tried to tear down and reload the CEVA DSP images, or when re-loading Tweety.
do_load_fw_and_drivers()
{
	modules_loaded=0
	modules="bb_buffers atdma_buffers buffer_pool30"
	for mod in $modules; do
		# Check whether module was already loaded. If not, load it.
		if ! lsmod 2>/dev/null | grep -qs $mod; then
			if [ $modules_loaded -eq 0 ]; then
				echo "Loading kernel module: $mod" 1>&2
			fi
			modules_loaded=$((modules_loaded+1))

			if [ -e /lib/${mod}.ko ]; then
				insmod /lib/${mod}.ko
			else
				modprobe $mod
			fi
			if [ $? -ne 0 ]; then
				echo "[FAILED]" 1>&2
				logger -p daemon.err -s "Failed to load kernel module: $mod" 1>&2
				return 2
			fi
		fi
	done
	if [ $modules_loaded -eq 0 ]; then
		logger -p daemon.err -s "Skipped loading kernel modules (all loaded already)." 1>&2
	fi

	# HACK: Disable Generic Receive Offload on the Ethernet interfaces to
	# prevent Sabine from crashing when it receives successive, large packets
	# (of size ~4k) on its packet socket. This is done in
	# /etc/init.d/S40network in Evolution, which we inherit in Velocity, but
	# it requires a newer factory image that the remote may-or-may-not have,
	# so we are going to work around it here too. See EVO-18629 for all of the
	# exciting details.
	for ethdev in $(ip link list 2>/dev/null | egrep -o 'eth[0-1]+'); do
		# NOTE: The network interface needs to be up to disable GRO or you will
		# get "Cannot get device feature names: Device or resource busy". That
		# should have already happened by the time this script is run, but just
		# in case it hasn't, bring the interface up now before running ethtool.
		logger -p daemon.info "Bringing up $ethdev"
		if ! ip link set dev $ethdev up; then
			logger -p daemon.err -s "Failed to bring up $ethdev" 1>&2
		fi
		logger -p daemon.info "Disabling GRO on $ethdev"
		if ! ethtool -K $ethdev gro off; then
			logger -p daemon.err -s "Failed to disable GRO on $ethdev" 1>&2
		fi
	done

	# FIXME: Loading the A-TDMA DSP images has a tendency to make the remote
	# lock up, even if they have been unloaded first. We don't have a good way
	# to tell if the DSP images have been loaded, but since we always load them
	# after the kernel modules, which also never get unloaded, use that as a
	# sentinel to make sure that we only load them once, on boot (or the first
	# time that we start the service, whenever that is).
	if [ $modules_loaded -gt 0 ]; then
		echo "Loading DSP images (running BigPig)" 1>&2
		cd /opt/idirect/dsp_images
		if ! bigpig -a; then
			echo "[FAILED]" 1>&2
			logger -p daemon.err -s "Failed loading DSP images (ran Bigpig)" 1>&2
			return 2
		fi
		logger -p daemon.info "Loaded DSP images successfully (ran Bigpig)"
		sleep 5
	else
		# (see FIXME comment above)
		logger -p daemon.err -s "Skipped loading DSP images (already loaded)." 1>&2
	fi

	# Run Tweety only once (using the same indication for when is the first time,
	# see above). In our testing, running it again caused CEVA demod lockup later,
	# when Sabine tries to tune to downstream.
	if [ $modules_loaded -gt 0 ]; then
		echo "Initializing modem (running Tweety)"
		tweety_cmd="tweety -tmfx -s 1000000 -a 4000000"
		if ! $tweety_cmd; then
			echo "[FAILED]" 1>&2
			logger -p daemon.err -s "Failed initializing modem (ran Tweety)" 1>&2
			return 2
		fi
		logger -p daemon.info "Initialized modem successfully (ran Tweety)"
		sleep 5
	fi

	return 0
}

# Unload the firmware (FPGA images, or equivalent) and drivers for this remote.
# return 0 on success.
do_unload_fw_and_drivers()
{
	# Run tweety only to disable demod and clear CW/PN configuration
	# option : -k -> No config mode
	#          -r -> Handling Rx
	#          -f -> Disable CLI
	#          -c -> Clear any leftover CW/PN configuration
	#          -w -> Set rx_freq, setting rx_freq=0, implies disable demod
	tweety_cmd="tweety -krfc -w 0"
	if ! $tweety_cmd > null; then
		echo "[FAILED]" 1>&2
		logger -p daemon.err -s "Failed disabling demod by Tweety" 1>&2
		return 2
	else
		logger -p daemon.info "Disabled demod (ran tweety)"
	fi

	# Reset the CEVAs. The board will lock up next time we call "bigpig -a" to
	# load the A-TDMA images or "bigpig -s" to load the SCPC images if we don't
	# do this on shutdown.
	#
	# FIXME: For now, only reset the CEVAs if the iDirect A-TDMA buffer driver
	# has been unloaded (which we do not do anywhere in this script). The
	# presence of that driver is used as a sentinel for loading the DSP images
	# in do_start(), so it only makes sense that we use it as a sentinel for
	# unloading them here. However, ideally, we should be able to unload/reload
	# the DSP images safely, without the risk of locking up the board. This
	# conditional loading/unloading of the DSP images is just a workaround for
	# some deeper issue.
	if ! lsmod 2>/dev/null | grep -qs atdma_buffers; then
		bigpig -r
		sleep 3
	else
		# (see FIXME comment above)
		logger -p daemon.err "Skipped unloading DSP images." 1>&2
	fi

	return 0
}

# The START_DAEMONS and STOP_DAEMONS variables will only be set when this
# script is sourced from the URT init script. If they are not, then this script
# is being run standalone, and we should try to parse our command line
# arguments.
if [ -z "$START_DAEMONS" ] && [ -z "$STOP_DAEMONS" ]; then
	case "$1" in
		load)
			do_load_fw_and_drivers
			;;

		unload)
			do_unload_fw_and_drivers
			;;

		*)
			echo "Usage: $0 load|unload" 1>&2
			exit 1
			;;
	esac
fi
