#!/bin/sh
#
# bootmisc.sh	Miscellaneous things to be done during bootup.
#
# Version:	@(#)bootmisc.sh  2.83  02-Oct-2001  miquels@cistron.nl
#

#
# HACK: We don't have fine-grained control over which services get started and
# which services get stopped on the iQ Desktop. If a service gets run on
# startup, it also gets run at shutdown. Only run this script at startup.
#
if [ -n "$1" ] && [ "$1" != "start" ]
then
	exit 0
fi

if [ -r /etc/default/rcS ]
then
	. /etc/default/rcS
fi

#
# Put a nologin file in /etc to prevent people from logging in before
# system startup is complete.
#
if [ "$DELAYLOGIN" = yes ]
then
  echo "System bootup in progress - please wait" > /etc/nologin
  cp /etc/nologin /etc/nologin.boot
fi

#
# Wipe /tmp (and don't erase `lost+found', `quota.user' or `quota.group')!
# Note that files _in_ lost+found _are_ deleted.
#
[ "$VERBOSE" != no ] && echo -n "Cleaning: /tmp "
for f in /tmp/*; do
	case $f in *lost+found|*quota*) continue ;; esac
	rm -r $f >/dev/null 2>&1
done
rm -r /tmp/.X*-lock >/dev/null 2>&1


#
# Clean up any stale locks.
#
[ "$VERBOSE" != no ] && echo -n "/var/lock "
for f in /var/lock/*; do
	case $f in *lost+found|*quota*) continue ;; esac
	rm -r $f >/dev/null 2>&1
done

#
# Clean up /var/run and create /var/run/utmp so that we can login.
#
[ "$VERBOSE" != no ] && echo -n "/var/run"
for f in /var/run/*; do
	case $f in *lost+found|*quota*|*utmp|*random-seed) continue ;; esac
	rm -r $f >/dev/null 2>&1
done
: > /var/run/utmp
[ "$VERBOSE" != no ] && echo "."

#
# Set pseudo-terminal access permissions.
#
if [ ! -c /dev/.devfsd ] && [ -c /dev/ttyp0 ]
then
	chmod 666 /dev/tty[p-za-e][0-9a-f]
	chown root:tty /dev/tty[p-za-e][0-9a-f]
fi

#
# Update /etc/motd.
#
if [ "$EDITMOTD" != no ]
then
	uname -a > /etc/motd.tmp
	sed 1d /etc/motd >> /etc/motd.tmp
	mv /etc/motd.tmp /etc/motd
fi

#
# Save kernel messages in /var/log/dmesg
#
dmesg -s 65536 > /var/log/dmesg

#
# Set sysctl parameters
#
if [ -x /sbin/sysctl ] && [ -f /etc/sysctl.conf ]
then
	/sbin/sysctl -p /etc/sysctl.conf
fi

#
# Set alignment handling for the arm platform
# https://www.kernel.org/doc/Documentation/arm/mem_alignment
#
if uname -m | grep -qs arm
then
	echo "2" > /proc/cpu/alignment
fi

: exit 0

