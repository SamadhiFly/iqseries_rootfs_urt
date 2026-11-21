#!/bin/sh
# Description: Store system clock into file
# This avoids any shadow file problems if manually setting passwd
# Mobility will also use system time for GPS validity checks

# The "reference date" is a hard-coded constant (in seconds since the UNIX
# epoch). It is used as a fallback when we are restoring the current date and
# time on first boot, in case the timestamp file does not exist. It is a known
# date that the current date must not be older than. It can also serve as a
# sanity check on the date in the timestamp file. They should not be orders of
# magnitude different.
if [ -r /usr/sbin/sabine ]; then
	# Sabine changes frequently. Get the date that it was built.
	reference_date=$(date -r /usr/sbin/sabine +%s 2>/dev/null)
fi
if [ -z "$reference_date" ]; then
	# Fri Apr 13 22:50:40 UTC 2018
	reference_date=1523659840
fi

# This is the timestamp file that is written when the system date and time
# changes, so that it can be restored on the next boot. (iDirect remote
# terminals do not have a persistent realtime clock. They lose the current date
# and time when they are powered off or rebooted. The purpose of this script is
# to save and restore the last known date from this file.)
timestamp_file=/common/timestamp

restore_date() {
	if [ -r $timestamp_file ]; then
		last_known_date="$(head -n1 $timestamp_file 2>/dev/null)"
		if [ -z "$last_known_date" ]; then
			echo "WARNING: No timestamp in ${timestamp_file}." 1>&2
			echo "Falling back to reference timestamp." 1>&2
			last_known_date=$reference_date
		elif ! echo $last_known_date | egrep -xqs '[0-9]+'; then
			echo "WARNING: The format of the timestamp in $timestamp_file is not recognized." 1>&2
			echo "Falling back to reference timestamp." 1>&2
			last_known_date=$reference_date
		elif [ $last_known_date -lt $reference_date ]; then
			echo "WARNING: Last known timestamp $last_known_date is too old." 1>&2
			echo "Discarding it in favor of the reference timestamp." 1>&2
			last_known_date=$reference_date
		fi
	else
		last_known_date=$reference_date
	fi

	current_date=$(date +%s 2>/dev/null)
	if [ -z "$current_date" ] || [ $current_date -lt $last_known_date ]; then
		# We have a date in seconds since the UNIX epoch, but "date -s" can't
		# actually set a new system date in that format. We need to convert it
		# into a more human-readable format that "date -s" can deal with.
		new_date_string="$(date -d "@${last_known_date}" +%Y%m%d%H%M.%S 2>/dev/null)"
		if [ -z "$new_date_string" ]; then
			echo "ERROR: Failed to convert the timestamp $last_known_date into a date string." 1>&2
		else
			echo "Setting the system date"
			date -s $new_date_string
		fi
	fi
}

save_date() {
	current_date=$(date +%s 2>/dev/null)
	if [ -n "$current_date" ] && [ $current_date -ge $reference_date ]; then
		if [ -r $timestamp_file ]; then
			last_saved_date="$(head -n1 $timestamp_file 2>/dev/null)"
			if ! echo $last_saved_date | egrep -xqs '[0-9]+'; then
				last_saved_date=0
			fi
		else
			last_saved_date=0
		fi

		if [ $last_saved_date -lt $current_date ]; then
			echo "Saving the system date to $timestamp_file"
			echo $current_date > $timestamp_file
		fi
	fi
}

while [ $# -gt 1 ]; do
	case "$1" in
		-f|--file)
			if [ -z "$2" ] || [ $# -lt 3 ]; then
				echo "Missing TIMESTAMP_FILE for -f/--file option" 1>&2
				exit 1
			fi
			timestamp_file="$2"
			shift
			;;

		*)
			echo "Invalid Argument: $1" 1>&2
			exit 1
			;;
	esac
	shift
done

case "$1" in
	start|restore)
		restore_date
		;;

	stop|save)
		save_date
		;;

	restart)
		;;

	status)
		date
		;;

	*)
		echo "usage: $0 [-f|--file TIMESTAMP_FILE] save|restore|status"
		exit 1
		;;
esac
