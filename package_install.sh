#!/bin/sh

#===============================================================================================================
#  Globals.
#===============================================================================================================
PKG_DIR=`dirname $0`;
temp_dir=`pwd`
export temp_dir
#store logs in /common folder for debugging
LOG=/common/install_iq.log
trap "cd $temp_dir/.. && /bin/rm -rf $temp_dir/" 0

file_list=""
update_dev=""
nms_file_hash=""
force_install=""

#===============================================================================================================
#  Functions
#===============================================================================================================
log()
{
    LOG="$1"
    shift
    DTG=`date "+%D-%R:%S"`
    echo -e "$DTG -- $*" >>$LOG
}

log_and_report()
{
    LOG="$1"
    shift
    errlev="$1"
    shift
    /bin/echo $*;
    DTG=`date "+%D-%R:%S"`
    echo -e "$DTG -- $*" >>$LOG
}

error_exit()
{
    LOG="$1"
    shift
    log_and_report $LOG syslog.err $2
    if [ -f "/tmp/restore_io_setting.sh" ]; then
        /tmp/restore_io_setting.sh 2>/dev/null
        log $LOG "Restored cache settings"
        echo "Restored cache settings"
    fi
    exit $1
}

# Run the given command more than once, giving up only after 5 attempts.
#
# NOTE: Be very careful when deciding where to use this function. Some commands really shouldn't be immediately
# re-executed if they fail. A non-zero return code really is supposed to mean "failed". However many iQ Desktop
# terminals shipped with a bug in the kernel that effectively causes random seg. faults, illegal instructions,
# memory corruption, and other horrible errors while running seemingly innocuous commands, like "chown" or "cp".
# Since we have to be able to upgrade from packages that have that bug, and it is seemingly random, this
# function attempts to work around it in the only way we can by running the given command multiple times in a
# row if it fails, and only returns an error after a number of attempts.
#
runcmdagain()
{
    local command="$1"
    shift
    local commandargs="$*"
    local runattempts=0
    local commandresult=1
    # sync filesystem before first attempt. On a normal scenario where commands succeed on the first attempt,
    # sync will be called once per every command that is wrapped with 'runcmdagain'.
    /bin/sync
    while [ $runattempts -lt 5 ] && [ $commandresult -ne 0 ]; do
        $command $commandargs
        local commandresult=$?
        local runattempts=$(($runattempts + 1))
        # sleep and sync after every failed attempt.
        if [ $commandresult -ne 0 ]; then
            /bin/sleep $((runattempts * 2))
            /bin/sync
        fi
    done
    return $commandresult
}

report_memory_status()
{
    #===============================================================================================================
    #  Check for available storage
    #===============================================================================================================
    echo "Check for available flash storage:  " | awk '{printf "%-62s", $0}'
    mnt_point=/mnt
    free_bytes=`/bin/df -Pk $mnt_point 2>/dev/null | /usr/bin/awk '{if($4 ~ /^[0-9]+$/){print $4*1024; exit 0;}}'`
    log $LOG "Available memory in flash: $free_bytes"
    echo -e "DONE ($free_bytes)"

    #===============================================================================================================
    #  Check for available RAM
    #===============================================================================================================
    echo -e "Check for available RAM:  " | awk '{printf "%-62s", $0}'
    ram_status=`/usr/bin/free`
    echo -e "$DTG -- Memory status:" >>$LOG
    echo -e "$ram_status" >>$LOG
    ram_free_mem=`/usr/bin/free | /bin/grep "Mem:" 2>/dev/null | /usr/bin/awk '{if($4 ~ /^[0-9]+$/){print $4; exit 0;}}'`
    echo -e "DONE ($ram_free_mem)"

    #===============================================================================================================
    #  Check for available /tmp status
    #===============================================================================================================
    echo "Check for /tmp status:  " | awk '{printf "%-62s", $0}'
    tmp_point=/tmp
    free_bytes=`/bin/df -Pk $tmp_point 2>/dev/null | /usr/bin/awk '{if($4 ~ /^[0-9]+$/){print $4*1024; exit 0;}}'`
    log $LOG "Free bytes in /tmp: $free_bytes"
    echo -e "DONE ($free_bytes)"
}

restore_io_settings()
{
    echo "Restoring cache settings:" | awk '{printf "%-62s", $0}'
    if [ -f "/tmp/restore_io_setting.sh" ]; then
        /tmp/restore_io_setting.sh 2>/dev/null
        log $LOG "Restored cache settings"
        echo -e "DONE"
    else
        echo -e "FAILED"
    fi
}

calculate_free_bytes_available()
{
    mnt_point=/mnt
    free_bytes=`/bin/df -Pk $mnt_point 2>/dev/null | /usr/bin/awk '{if($4 ~ /^[0-9]+$/){print $4*1024; exit 0;}}'`
    echo $free_bytes
}

#===============================================================================================================
#                                                   M A I N
#===============================================================================================================

#===============================================================================================================
#  Print package installation beginning to log file.
#===============================================================================================================
>$LOG;
log_and_report $LOG syslog.info "=========  Base Rootfs Package Installation script starting  ========="
pkg_info=`/usr/sbin/pkgstat -l 2>/dev/null`
echo -e "$DTG -- Package installed status:" >>$LOG
echo -e "$pkg_info" >>$LOG

#===============================================================================================================
#  Parse options from command line provided by Gargoyle.
#  Filter out the -f options and put them into a "pseudo-array", a string of space-separated strings.
#  Then create a new command line containing only the position-defined parameters.
#===============================================================================================================

position_params=""

while [ $# -gt 0 ]
do
    while getopts f: flag;
    do
        case $flag in
            f)
            file_list="${file_list} $OPTARG"
            ;;
        esac
    done
    shift $((OPTIND -1)); OPTIND=0

    if [ $1 ]; then
        position_params="${position_params} $1"
        shift
    fi
done

set -- $position_params
update_dev=$1
nms_file_hash=$2
force_install=$3

#===============================================================================================================
#  Process parameters from command line
#===============================================================================================================

# HACK: Can't calculate package hash if Evolution was the one that executed this install
# script because the package file is already gone. We can detect this by checking for the
# hard-coded name of the directory where Sabine's LinuxPackageManager extracts the package.
# Calculate an alternative (not really valid) hash on the version file. This allows the
# package to be installed from the Evolution factory partition, for backwards compatibility.
if echo "$temp_dir" | /bin/grep -qs Sabine_Pkg_Download_; then
    nms_file_hash=`echo "iqseries_rootfs_urt_3.5.2.1-12131" | sha512sum 2>/dev/null | awk '{print $1}'`
	log_and_report $LOG syslog.info "Package file not available, Generating Alternative hash."
elif [ -z "$nms_file_hash" ]; then
    if [ -f "iqseries_rootfs_urt_3.5.2.1-12131.pkg" ]; then
        nms_file_hash=`sha512sum "iqseries_rootfs_urt_3.5.2.1-12131.pkg" 2>/dev/null | awk '{print $1}'`
    elif [ -f "../iqseries_rootfs_urt_3.5.2.1-12131.pkg" ]; then
        nms_file_hash=`sha512sum "../iqseries_rootfs_urt_3.5.2.1-12131.pkg" 2>/dev/null | awk '{print $1}'`
    fi
	if [ -n "$nms_file_hash" ] && [ `printf "%s" "$nms_file_hash" | wc -c` != 128 ]; then
    	error_exit $LOG 1 "Package Install: File hash is not a valid SHA-512 checksum: $nms_file_hash."
    fi
fi

if [ -n "$force_install" ] && [ "$force_install" = "force" ];then
    force=true
else
    force=false
fi

if [ -z "$update_dev" ]; then
    error_exit $LOG 1 "Package Install: Software partition not specified."
fi
if echo $update_dev | /bin/egrep -xqs '/mnt/[^ \/]+'; then
    if ! echo $update_dev | /bin/grep -Eqs 'factory|active[0-9]+'; then
        error_exit $LOG 1 "Package Install: FAILED, invalid software partition mount point: $update_dev."
    fi
elif echo $update_dev | /bin/egrep -xqs 'factory|active[0-9]+'; then
    update_dev=/mnt/$update_dev
else
    error_exit $LOG 1 "Package Install: FAILED, unsupported software partition: $update_dev."
fi

boot_part=`/bin/egrep -o 'partition=\S+' /proc/cmdline | cut -d= -f2`
if [ -z "$boot_part" ]; then
    error_exit $LOG 1  "Package Install: FAILED to get boot partition."
fi
if ! echo $boot_part | /bin/grep -Fqs '/'; then
    boot_part=/mnt/$boot_part
fi
if [ "$boot_part" = "$update_dev" ]; then
    error_exit $LOG 1  "Package Install: FAILED, may not update currently booted filesystem: $update_dev."
fi
if [ "$update_dev" = "/mnt/factory" ] && [ "$force" = "false" ]; then
    error_exit $LOG 1  "Package Install: FAILED, may not update the \"Factory\" filesystem: $update_dev."
fi
if [ "$update_dev" = "/mnt/common" ] || [ "$update_dev" = "/common" ]; then
    error_exit $LOG 1  "Package Install: FAILED, may not update the \"Common\" filesystem: $update_dev."
fi
if [ "$update_dev" = "/mnt/sysopt" ] || [ "$update_dev" = "/sysopt" ]; then
    error_exit $LOG 1  "Package Install: FAILED, may not update the \"Sysopt\" filesystem: $update_dev."
fi

#===============================================================================================================
#  Determine hardware model number and using the boardModel.xlate file the board family.
#===============================================================================================================
echo "Determining board model/hardware family:  " | awk '{printf "%-62s", $0}'
if [ ! -c "/dev/mtd3" ]; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: /dev/mtd3 is not a character special device, installation aborted."
fi
hardware_family=`/usr/bin/awk -F'[ \t:"]+' '{if($2 == "model"){print $3; exit 0;}}' /dev/mtd3`
if [ "$hardware_family" = "IQEdge" ]; then
	hardware_family="IQ200Rackmount"	
fi
if echo $hardware_family | /bin/egrep -Fqs '[0-9]+'; then
    # We have the hardware model number. Get the board family.
    board_model_number=$hardware_family
    log $LOG "Board Model: $board_model_number"
    if [ ! -f "boardModel.xlate" ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: File not found: boardModel.xlate, installation aborted."
    fi
    hardware_family=`/usr/bin/awk '{if($1 == "'$board_model_number'"){print $2; exit 0;}}' boardModel.xlate`
    log $LOG "Hardware Family: $hardware_family"
    if [ -z "$hardware_family" ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: Unsupported hardware family $hardware_family, installation aborted."
    fi
    echo -e "DONE"
elif [ -n "$hardware_family" ]; then
    # We have the board family. Get the hardware model number.
    log $LOG "Hardware Family: $hardware_family"
    if [ ! -f "boardModel.xlate" ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: File not found: boardModel.xlate, installation aborted."
    fi
    board_model_number=`/usr/bin/awk '{if(tolower($2) == tolower("'$hardware_family'")){print $1; exit 0;}}' boardModel.xlate`
    log $LOG "Board Model: $board_model_number"
    if [ -z "$board_model_number" ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: Unsupported hardware model $board_model_number, installation aborted."
    fi
    echo -e "DONE"
else
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: Cannot determine hardware model number from /dev/mtd3, installation aborted."
fi

#===============================================================================================================
#  Ensure we have all the files identified in the install_file_map, all are not zero length.
#===============================================================================================================
echo "Ensure we have all required files:  " | awk '{printf "%-62s", $0}'
while read src_fname targ_fname src_fsize targ_fmode targ_fowner targ_fgroup targ_file_hw; do
    #===========================================================================================================
    #  Parse values from map file line.
    #===========================================================================================================
    if [ "$src_fname" = "DIRECTORY" -o "$src_fname" = "SYMLINK" ]; then
        continue
    fi
    if [ ! -f $src_fname ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: Required file not found in package: $src_fname, installation aborted."
    fi;
    if [ -f $src_fname -a ! -s $src_fname ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: Required file is zero length in package: $src_fname, installation aborted."
    fi;
done <install_file_map
echo -e "DONE"

#===============================================================================================================
#  Prepare RAM for upgrade. Mainly to avoid OOM killing of process.
#===============================================================================================================
report_memory_status
#NOTE: copied from EVO implementation.
echo "save cache settings and drop cache:  " | awk '{printf "%-62s", $0}'
log $LOG "save cache settings and drop cache"
#this function change io strategy to make OS flush cache more frequently, so to avoid OOM issue caused by untar the pkg
#first save old settings as a script, later run that script to restore setting.
echo "sync "  > /tmp/restore_io_setting.sh
echo echo `cat /proc/sys/vm/dirty_ratio                `  " > /proc/sys/vm/dirty_ratio               "  >> /tmp/restore_io_setting.sh
echo echo `cat /proc/sys/vm/dirty_background_ratio     `  " > /proc/sys/vm/dirty_background_ratio    "  >> /tmp/restore_io_setting.sh
echo echo `cat /proc/sys/vm/dirty_writeback_centisecs  `  " > /proc/sys/vm/dirty_writeback_centisecs "  >> /tmp/restore_io_setting.sh
echo echo `cat /proc/sys/vm/vfs_cache_pressure         `  " > /proc/sys/vm/vfs_cache_pressure        "  >> /tmp/restore_io_setting.sh
echo echo `cat /proc/sys/vm/dirty_expire_centisecs     `  " > /proc/sys/vm/dirty_expire_centisecs    "  >> /tmp/restore_io_setting.sh

echo 2 > /proc/sys/vm/dirty_ratio
echo 2 > /proc/sys/vm/dirty_background_ratio
echo 20 > /proc/sys/vm/dirty_writeback_centisecs
echo 150 > /proc/sys/vm/vfs_cache_pressure
echo 30  > /proc/sys/vm/dirty_expire_centisecs
sync
echo 3 > /proc/sys/vm/drop_caches
chmod +x /tmp/restore_io_setting.sh
echo -e "DONE"

#===============================================================================================================
#  Check for available RAM after dropping caches
#===============================================================================================================
echo -e "Check for available RAM after cache drop:  " | awk '{printf "%-62s", $0}'
ram_status=`/usr/bin/free`
echo -e "$DTG -- Memory status after drop cache:" >>$LOG
echo -e "$ram_status" >>$LOG
ram_free_mem=`/usr/bin/free | /bin/grep "Mem:" 2>/dev/null | /usr/bin/awk '{if($4 ~ /^[0-9]+$/){print $4; exit 0;}}'`
echo -e "DONE ($ram_free_mem)"
    
#===============================================================================================================
#  Erase the /common/pkgDb info for this device. Set status file to being updated.
#===============================================================================================================
partition_name=`echo $update_dev | /usr/bin/awk -F'/' '{print $NF}'`
echo "Delete /common/pkgDb/$partition_name:  " | awk '{printf "%-62s", $0}'
if ! /bin/rm -rf /common/pkgDb/$partition_name; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: Remove of /common/pkgDb/$partition_name failed, installation aborted."
fi
if ! /bin/mkdir -p /common/pkgDb/$partition_name; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: Creation of /common/pkgDb/$partition_name failed, installation aborted."
fi
if ! /bin/chown root:root /common/pkgDb/$partition_name; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: Failed to set owner/group on directory: /common/pkgDb/$partition_name, installation aborted."
fi
if ! /bin/chmod 755 /common/pkgDb/$partition_name; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: Failed to set mode on directory: /common/pkgDb/$partition_name, installation aborted."
fi
echo "Being updated by package: iqseries_rootfs_urt_3.5.2.1-12131" >/common/pkgDb/$partition_name/status
if [ "$?" != "0" ]; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: Failed to write file: /common/pkgDb/$partition_name/status, installation aborted."
fi
if ! /bin/chown root:root /common/pkgDb/$partition_name/status; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: Failed to set owner/group on file: /common/pkgDb/$partition_name/status, installation aborted."
fi
if ! /bin/chmod 644 /common/pkgDb/$partition_name/status; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: Failed to set mode on file: /common/pkgDb/$partition_name/status, installation aborted."
fi
echo -e "DONE"

#===============================================================================================================
#  Run checkinstall script if one exists.
#===============================================================================================================
if [ -f "$temp_dir/checkinstall" ]; then
    echo "Running package checkinstall scriptlet:  " | awk '{printf "%-62s", $0}'
    log $LOG "Running package checkinstall scriptlet."
    /bin/chmod 750 $temp_dir/checkinstall
    $temp_dir/checkinstall $temp_dir
    rc=$?
    if [ "$rc" != "0" ]; then
        echo -e "FAILED"
        error_exit $LOG $rc "Package Install: Scriptlet checkinstall failed, installation aborted."
    fi
    echo "DONE"
fi

#===========================================================================================================
#  Mount the partition to be updated.
#===========================================================================================================
mount_point=/mnt
if ! /bin/mount | /usr/bin/awk '{if($3 == "'$mount_point'"){print $1" "$3}}' | /bin/grep -qs "/dev/ubi0_0 $mount_point"; then
    echo "Mounting $mount_point partition:  " | awk '{printf "%-62s", $0}'
    if ! /bin/mount -t ubifs /dev/ubi0_0 $mount_point; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: FAILED to mount device: /dev/ubi0_0, installation aborted."
    fi
    trap "cd $temp_dir/.. && /bin/umount $mount_point && /bin/rm -rf $temp_dir/" 0
else
    echo "Skipping mount of $mount_point partition:  " | awk '{printf "%-62s", $0}'
fi
echo -e "DONE"

#===============================================================================================================
#  Delete the existing operating system files on the update device.
#===============================================================================================================
echo "Recreating $update_dev:  " | awk '{printf "%-62s", $0}'
if ! /bin/rm -rf $update_dev; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: FAILED to delete $update_dev, installation aborted."
fi
if ! /bin/mkdir -p $update_dev; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: Creation of $update_dev failed, installation aborted."
fi
if ! /bin/chown root:root $update_dev; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: FAILED to set owner/group on directory: $update_dev, installation aborted."
fi
if ! /bin/chmod 700 $update_dev; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: FAILED to set mode on directory: $update_dev, installation aborted."
fi
if ! /bin/sync; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: FAILED to sync changes to $update_dev to disk, installation aborted."
fi
echo -e "DONE"

#===============================================================================================================
#  Set the package install status file to failed before we start any updates.
#===============================================================================================================
if ! /bin/mkdir -p $update_dev/pkg/iqseries_rootfs_urt_3.5.2.1-12131; then
    error_exit $LOG 1 "Package Install: Failed while creating package info directory, installation aborted."
fi
if ! echo "Failed" >$update_dev/pkg/iqseries_rootfs_urt_3.5.2.1-12131/status; then
    error_exit $LOG 1 "Package Install: Failed while updating installation status file, installation aborted."
fi

#===============================================================================================================
#  Run preinstall script if one exists.
#===============================================================================================================
/bin/rm -f iqseries_rootfs_urt_3.5.2.1-12131/UNINSTALLED
if [ -f "$temp_dir/preinstall" ]; then
    echo "Running package preinstall scriptlet:  " | awk '{printf "%-62s", $0}'
    log $LOG "Running package preinstall scriptlet."
    /bin/chmod 750 $temp_dir/preinstall
    $temp_dir/preinstall $temp_dir $update_dev
    rc=$?
    if [ "$rc" != "0" ]; then
        echo -e "FAILED"
        error_exit $LOG $rc "Package Install: Scriptlet preinstall failed, installation aborted."
    fi
    echo -e "DONE"
fi

#===============================================================================================================
#  Make sure that we have enough space on disk for the new root filesystem.
#===============================================================================================================
sync
echo "Checking free space:  " | awk '{printf "%-62s", $0}'
free_bytes=$(calculate_free_bytes_available)
if ! echo $free_bytes | /bin/egrep -xqs '[0-9]+' || [ $free_bytes -le 0 ]; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: FAILED to get the free space on $mount_point: $free_bytes, installation aborted."
fi
log $LOG "Free flash bytes after deleting update partition: $free_bytes"
required_bytes=0

if [ -z "$file_list" ]; then
    for tarball in rootfs.tar.bz2; do
        log $LOG "Checking space required for tar archive: $tarball"
        tarball_bytes=`/usr/bin/bunzip2 -c $tarball 2>/dev/null | /bin/tar tvf - 2>/dev/null | /usr/bin/awk 'BEGIN{total_size=0} {if($3 ~ /[0-9]+/){total_size += $3}} END{print total_size}'`
        if ! echo $tarball_bytes | /bin/egrep -xqs '[0-9]+' || [ $tarball_bytes -le 0 ]; then
            echo -e "FAILED"
            error_exit $LOG 1 "Package Install: FAILED to calculate the expanded size of archive $tarball: $tarball_bytes, installation aborted."
        fi
        required_bytes=$((required_bytes+tarball_bytes))
        if ! echo $required_bytes | /bin/egrep -xqs '[0-9]+' || [ $required_bytes -le 0 ]; then
            echo -e "FAILED"
            error_exit $LOG 1 "Package Install: FAILED to add $tarball_bytes to required size: $required_bytes, installation aborted."
        fi
    done
else
    set -- $file_list
    while [ $# -gt 0 ]
    do
        filespec=$1
        shift
        pkgname=`echo $filespec | /usr/bin/awk -F':' '{print $1}'`
        tarball=`echo $filespec | /usr/bin/awk -F':' '{print $2}'`
        offset=`echo $filespec | /usr/bin/awk -F':' '{print $3}'`
        log $LOG "Checking space required for tar archive: $tarball"
        tarball_bytes=`/usr/bin/tail -c +$(($offset + 1)) $pkgname | /usr/bin/bunzip2 2>/dev/null | /bin/tar -tv 2>/dev/null  | /usr/bin/awk 'BEGIN{total_size=0} {if($3 ~ /[0-9]+/){total_size += $3}} END{print total_size}'`
        if ! echo $tarball_bytes | /bin/egrep -xqs '[0-9]+' || [ $tarball_bytes -le 0 ]; then
            echo -e "FAILED"
            error_exit $LOG 1 "Package Install: FAILED to calculate the expanded size of archive $tarball: $tarball_bytes, installation aborted."
        fi
        required_bytes=$((required_bytes+tarball_bytes))
        if ! echo $required_bytes | /bin/egrep -xqs '[0-9]+' || [ $required_bytes -le 0 ]; then
            echo -e "FAILED"
            error_exit $LOG 1 "Package Install: FAILED to add $tarball_bytes to required size: $required_bytes, installation aborted."
        fi
    done
fi

if [ $required_bytes -gt $free_bytes ]; then
    log $LOG "Without compression required Bytes $required_bytes > Free Bytes $free_bytes"
    # Even in worst case, 40MB of free bytes is most likely to work for a rootFS of size upto 46MB in a zo compressed file system(see here - _factoryify.sh)
    # so relaxing the minimum free bytes required for upgrade to 40MB for rootFS size of 46MB
    max_allowed_rootfs_size=48234496
    if [ $required_bytes -lt $max_allowed_rootfs_size ]; then
        min_required_bytes=41943040
        if [ $min_required_bytes -gt $free_bytes ]; then
            echo -e "FAILED"
            needed_bytes=$((min_required_bytes-free_bytes))
            error_exit $LOG 1 "Package Install: $needed_bytes more bytes required on $mount_point to install the package, installation aborted."
        fi
    else
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: roofs size $required_bytes > max allowed rootfs size $max_allowed_rootfs_size, installation aborted."
    fi
fi
echo -e "DONE ($free_bytes)"

#===============================================================================================================
#  Hard link the files from the current root filesystem to the new one.
#===============================================================================================================
partition_name=`echo $update_dev | /usr/bin/awk -F'/' '{print $NF}'`
if [ "$partition_name" != "factory" ]; then
    echo "Hard linking $boot_part to $update_dev:  " | awk '{printf "%-62s", $0}'
    if [ -z "$boot_part" ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: FAILED to get boot partition, installation aborted."
    fi
    if [ ! -d "$boot_part" ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: Boot partition $boot_part is not a directory, installation aborted."
    fi
    if [ ! -x "$boot_part/bin/busybox" ] || [ ! -h "$boot_part/bin/sh" ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: Boot partition $boot_part does not appear to have a valid base package, installation aborted."
    fi
    if ! /bin/cp -al $boot_part/* $update_dev/; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: FAILED to hard link all files in $boot_part to $update_dev, installation aborted."
    fi
    if [ -e $update_dev/pkg ] && ! /bin/rm -rf $update_dev/pkg; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: FAILED to delete the outdated $update_dev/pkg from $boot_part, installation aborted."
    fi
    if ! /bin/sync; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: FAILED to sync changes to $update_dev to disk, installation aborted."
    fi
    if [ ! -x "$update_dev/bin/busybox" ] || [ ! -h "$update_dev/bin/sh" ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: FAILED to validate base package installation on $update_dev, installation aborted."
    fi
else
    echo "Skipping hard linking for factory:  " | awk '{printf "%-62s", $0}'
fi
log $LOG "Hard linking finished, Available flash memory: $(calculate_free_bytes_available)"
echo -e "DONE ($(calculate_free_bytes_available))"

#===============================================================================================================
#  Install the rootfs signed and unsigned tarballs.
#===============================================================================================================
export EXTRACT_UNSAFE_SYMLINKS=1
if ! cd $update_dev; then
    error_exit $LOG 1 "Package Install: FAILED to change to directory: $update_dev, installation aborted."
fi
pkg_name=iqseries_rootfs_urt_3.5.2.1-12131
if [ -z "$file_list" ]; then
    for tarball in rootfs.tar.bz2; do
        echo "Installing tar archive: $tarball:  " | awk '{printf "%-62s", $0}'
        /bin/mkdir -p $update_dev/pkg/$pkg_name
        if ! echo "Failed" >$update_dev/pkg/$pkg_name/status; then
            echo -e "FAILED"
            error_exit $LOG 1 "Package Install: FAILED while updating installation status file."
        fi
        if ! /usr/bin/bunzip2 -c $temp_dir/$tarball | tar xf -; then
            echo -e "FAILED"
            error_exit $LOG 1 "Package Install: FAILED to untar archive: $tarball, installation aborted."
        fi
        log $LOG "Installed tar archive: $tarball, Available flash memory: $(calculate_free_bytes_available)"
        echo -e "DONE ($(calculate_free_bytes_available))"
    done
else
    set -- $file_list
    while [ $# -gt 0 ]
    do
        filespec=$1
        shift
        pkg_file=`echo $filespec | /usr/bin/awk -F':' '{print $1}'`
        tarball=`echo $filespec | /usr/bin/awk -F':' '{print $2}'`
        offset=`echo $filespec | /usr/bin/awk -F':' '{print $3}'`
        echo "Installing tar archive: $tarball:  " | awk '{printf "%-62s", $0}'
        /bin/mkdir -p $update_dev/pkg/$pkg_name
        if ! echo "Failed" >$update_dev/pkg/$pkg_name/status; then
            echo -e "FAILED"
            error_exit $LOG 1 "Package Install: FAILED while updating installation status file."
        fi
        if ! /usr/bin/tail -c +$(($offset + 1)) $pkg_file | /usr/bin/bunzip2 2>/dev/null | /bin/tar x; then
            echo -e "FAILED"
            error_exit $LOG 1 "Package Install: FAILED to untar archive: $tarball, installation aborted."
        fi
        log $LOG "Installed tar archive: $tarball, Available flash memory: $(calculate_free_bytes_available)"
        echo -e "DONE ($(calculate_free_bytes_available))"
    done
fi
if ! /bin/sync; then
    error_exit $LOG 1 "Package Install: FAILED to sync unpacked $tarball to disk, installation aborted."
fi
if ! echo "Success" >$update_dev/pkg/$pkg_name/status; then
    error_exit $LOG 1 "Package Install: FAILED while updating installation status file."
fi

cd $temp_dir || error_exit $LOG 1 "Package Install: FAILED to change to directory: $temp_dir, installation aborted."

#===============================================================================================================
#  Echo out the supplied file hash.
#===============================================================================================================
if ! echo "$nms_file_hash" > $update_dev/pkg/iqseries_rootfs_urt_3.5.2.1-12131/nms_hash; then
    error_exit $LOG 1 "Package Install: Failed to write nms_hash, installation aborted.";
fi

#===============================================================================================================
#  Update our bootloader, if required.
#===============================================================================================================
if [ -f uboot_env.lua ]; then
    echo "Running the latest u-boot env upgrade:  " | awk '{printf "%-62s", $0}'
    if [ ! -x $update_dev/usr/bin/lua ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: lua is not installed in the target environment on $update_dev, installation aborted."
    fi
    if ! $update_dev/usr/bin/lua uboot_env.lua; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: u-boot environment update failed, installation aborted."
    fi
    echo -e "DONE"
fi
if [ -f $temp_dir/common_10_128M ]; then
    echo "Running the latest u-boot upgrade:  " | awk '{printf "%-62s", $0}'
    if [ ! -x $update_dev/usr/sbin/flashcp ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: flashcp is not installed in the target environment on $update_dev, installation aborted."
    fi
    if [ ! -x $update_dev/usr/bin/strings ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: strings is not installed in the target environment on $update_dev, installation aborted."
    fi
    if [ ! -e /proc/mtd ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: FAILED to parse /proc/mtd, installation aborted."
    fi
    uboot_chardev=`/usr/bin/awk 'BEGIN{FS="[\":\r\t\n ]+"} {if($4 ~ /u-boot-initramfs-fdt/){if($1 ~ /\/dev\/.+/){print $1}else{print "/dev/"$1}}}' /proc/mtd 2>/dev/null`
    if [ -z "$uboot_chardev" ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: FAILED to get the u-boot character device from /proc/mtd, installation aborted."
    fi
    if [ ! -c $uboot_chardev ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: u-boot character device $uboot_chardev does not exist, installation aborted."
    fi
    installed_ubootbundle_version=`$update_dev/usr/bin/strings $uboot_chardev 2>/dev/null | /bin/egrep -i 'common_10\S+\s+[0-9]+\.[0-9]+' | /bin/egrep -o '[0-9]+\.[0-9]+(\.[0-9]+)?'`
    if [ -z "$installed_ubootbundle_version" ]; then
        # Early releases of the u-boot/initramfs/fdt bundle were unversioned. If the board is
        # running such an old release, arbitrarily set the version number to "1.0" so that our
        # version check still works properly. The first versioned release of the bundle was
        # "1.4".
        installed_ubootbundle_version=1.0
    fi
    log $LOG "u-boot bundle version: $installed_ubootbundle_version"
    new_ubootbundle_version=`$update_dev/usr/bin/strings $temp_dir/common_10_128M 2>/dev/null | /bin/egrep -i 'common_10\S+\s+[0-9]+\.[0-9]+' | /bin/egrep -o '[0-9]+\.[0-9]+(\.[0-9]+)?'`
    if [ -z "$new_ubootbundle_version" ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: FAILED to get the latest u-boot bundle version, installation aborted."
    fi
    log $LOG "Latest u-boot bundle version: $new_ubootbundle_version"
    if [ "$installed_ubootbundle_version" = "$new_ubootbundle_version" ]; then
        log $LOG "u-boot bundle v$installed_ubootbundle_version is already up-to-date"
        echo -e "SKIPPED"
    elif [ `printf "${installed_ubootbundle_version}\n${new_ubootbundle_version}\n" | sort -n | tail -n 1` = "$installed_ubootbundle_version" ]; then
        log $LOG "u-boot bundle v$installed_ubootbundle_version is newer than \"latest\" u-boot bundle v$new_ubootbundle_version"
        echo -e "SKIPPED"
    else
        log $LOG "Updating u-boot bundle v$installed_ubootbundle_version to v$new_ubootbundle_version"
        if ! $update_dev/usr/sbin/flashcp $temp_dir/common_10_128M $uboot_chardev >> $LOG 2>&1; then
            echo -e "FAILED"
            error_exit $LOG 1 "Package Install: FAILED to update u-boot, installation aborted."
        fi
        echo -e "DONE"
    fi
    if ! /bin/rm -f $temp_dir/common_10_128M; then
        # Don't abort. Just warn about the failure to remove the u-boot bundle since it won't
        # affect the installation, but *something* is definitely wrong here...
        log_and_report $LOG 1 "Package Install: FAILED to delete $temp_dir/common_10_128M after flashing it."
    fi

fi
if [ -f $temp_dir/boot-sectors.bin ]; then
    echo "Running the latest bootloader upgrade:  " | awk '{printf "%-62s", $0}'
    if [ ! -x $update_dev/usr/sbin/flashcp ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: flashcp is not installed in the target environment on $update_dev, installation aborted."
    fi
    if [ ! -x $update_dev/usr/bin/strings ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: strings is not installed in the target environment on $update_dev, installation aborted."
    fi
    if [ ! -e /proc/mtd ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: FAILED to parse /proc/mtd, installation aborted."
    fi
    bootloader_chardev=`/usr/bin/awk 'BEGIN{FS="[\":\r\t\n ]+"} {if($4 ~ /(primary\-)?boot?loader/){if($1 ~ /\/dev\/.+/){print $1}else{print "/dev/"$1}}}' /proc/mtd 2>/dev/null`
    if [ -z "$bootloader_chardev" ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: FAILED to get the bootloader character device from /proc/mtd, installation aborted."
    fi
    if [ ! -c $bootloader_chardev ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: bootloader character device $bootloader_chardev does not exist, installation aborted."
    fi
    bootloader_version=`$update_dev/usr/bin/strings $bootloader_chardev 2>/dev/null | /bin/egrep -i 'boot\s*loader\s+v?[0-9]+\.[0-9]+' | /bin/egrep -o '[0-9]+\.[0-9]+'`
    if [ -z "$bootloader_version" ]; then
        # Early releases of the primary bootloader were unversioned. If the board is running such
        # an old release, arbitrarily set the version number to "1.0" so that our version check
        # still works properly. The first versioned release of the bootloader according to our
        # source control history was 1.3.
        bootloader_version=1.0
    fi
    log $LOG "Primary bootloader version: $bootloader_version"
    bootsectors_version=`$update_dev/usr/bin/strings $temp_dir/boot-sectors.bin 2>/dev/null | /bin/egrep -i 'boot\s*loader\s+v?[0-9]+\.[0-9]+' | /bin/egrep -o '[0-9]+\.[0-9]+'`
    if [ -z "$bootsectors_version" ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: FAILED to get the latest bootloader version, installation aborted."
    fi
    log $LOG "Latest bootloader version: $bootsectors_version"
    if [ "$bootloader_version" = "$bootsectors_version" ]; then
        log $LOG "Primary bootloader v$bootloader_version is already up-to-date"
        echo -e "SKIPPED"
    elif [ `printf "${bootloader_version}\n${bootsectors_version}\n" | sort -n | tail -n 1` = "$bootloader_version" ]; then
        log $LOG "Primary bootloader v$bootloader_version is newer than \"latest\" bootloader v$bootsectors_version"
        echo -e "SKIPPED"
    else
        log $LOG "Updating primary bootloader v$bootloader_version to v$bootsectors_version"
        if ! $update_dev/usr/sbin/flashcp $temp_dir/boot-sectors.bin $bootloader_chardev >> $LOG 2>&1; then
            echo -e "FAILED"
            error_exit $LOG 1 "Package Install: FAILED to update the primary bootloader, installation aborted."
        fi
        echo -e "DONE"
    fi
    if ! /bin/rm -f $temp_dir/boot-sectors.bin; then
        # Don't abort. Just warn about the failure to remove the bootloader file since it won't
        # affect the installation, but *something* is definitely wrong here...
        log_and_report $LOG 1 "Package Install: FAILED to delete $temp_dir/boot-sectors.bin after flashing it."
    fi
fi

#===============================================================================================================
#  Update our kernel, if a new one is included in the package.
#===============================================================================================================
KERNEL_UPDATE_FILE=/common/kernel_update
get_current_kernel()
{
if [ ! -e /proc/mtd ]; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: FAILED to parse /proc/mtd, installation aborted."
fi

local bootdir_chardev=`/usr/bin/awk 'BEGIN{FS="[\":\r\t\n ]+"} {if($4 ~ "boot-dir"){if($1 ~ /\/dev\/.+/){print $1}else{print "/dev/"$1}}}' /proc/mtd 2>/dev/null`

if [ -z "$bootdir_chardev" ]; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: FAILED to get the boot_dir character device from /proc/mtd, installation aborted."
fi
if [ ! -c $bootdir_chardev ]; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: boot_dir character device $bootdir_chardev does not exist,installation aborted."
fi

local numberofentry=$(printf "%d" 0x$(hexdump -s 0 -n 1 $bootdir_chardev | awk 'NR==1 {print $2}'))

local i=1
local entry_flag
while [ "$i" -le "$numberofentry" ]; do
	entry_flag=$(hexdump -s $((i*4)) -n 1 $bootdir_chardev | awk 'NR==1 {print $2}')
	if [ "$entry_flag" == 00fd ]; then
		break
	fi
	i=$(($i + 1))
done

local entry_offset=$(hexdump -s $((i*4+2)) -n 1 $bootdir_chardev | awk 'NR==1 {print $2}')
local current_kernel

case "$entry_offset" in

    004a) current_kernel='kernel-1'
        ;;
    008a) current_kernel='kernel-2'
        ;;
    00ca) current_kernel='kernel-3'
        ;;
       *) echo -e "FAILED"
          error_exit $LOG 1 "Package Install: invalid current_kernel, kernel switch aborted."
        ;;
esac

    log  $LOG "curent kernel is $current_kernel"
    echo $current_kernel
}

flash_kernel_partition()
{
    log $LOG "Updating kernel on $1"
    if ! $update_dev/usr/sbin/flashcp $temp_dir/kern $1 >> $LOG 2>&1; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: FAILED to update the kernel, installation aborted."
    fi
    echo -e "DONE"
}

get_mtd_partition()
{
    local chardev=$(/usr/bin/awk -v x=$1 'BEGIN{FS="[\":\r\t\n ]+"} {if($4 ~ x){if($1 ~ /\/dev\/.+/){print $1}else{print "/dev/"$1}}}' /proc/mtd 2>/dev/null)

    if [ -z "$chardev" ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: FAILED to get the $1 character device from /proc/mtd, installation aborted."
    fi
    if [ ! -c $chardev ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: kernel character device $chardev does not exist, installation aborted."
    fi
    echo "$chardev"
}

if [ -f $temp_dir/kern ]; then
    echo "Running the latest kernel upgrade:  " | awk '{printf "%-62s", $0}'
    if [ ! -x $update_dev/usr/sbin/flashcp ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: flashcp is not installed in the target environment on $update_dev, installation aborted."
    fi
    case "$(get_current_kernel)" in
        "kernel-1") flash_kernel_partition $(get_mtd_partition "kernel-2")
                    flash_kernel_partition $(get_mtd_partition "kernel-3")
                    ;;
        "kernel-2") flash_kernel_partition $(get_mtd_partition "kernel-3")
                    ;;
        "kernel-3") flash_kernel_partition $(get_mtd_partition "kernel-2")
                    ;;
    esac

    if ! /bin/rm -f $temp_dir/kern; then
        log_and_report $LOG 1 "Package Install: FAILED to delete $temp_dir/kern after flashing it."
    fi
    #Activate process will check this file for successful installation
    >$KERNEL_UPDATE_FILE
fi

#===============================================================================================================
#  Based on the install_file_map, create any directories specified.
#===============================================================================================================
echo "Create directories in $update_dev.  " | awk '{printf "%-62s", $0}'
while read src_fname dir_name dir_mode dir_owner dir_group rest; do
    if [ "$src_fname" != "DIRECTORY" ]; then
        continue
    fi
    #===========================================================================================================
    #  Create directory, set mode, owner and group.
    #===========================================================================================================
    if [ -z "$first" ]; then
        first=1
        echo -e "";
    fi
    echo "  $dir_name  " | awk '{printf "%-62s", $0}'
    log $LOG "Creating directory: $dir_name, $dir_mode, $dir_owner, $dir_group."
    if ! runcmdagain /bin/mkdir -p -m $dir_mode $update_dev/$dir_name; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: Failed to create directory: $update_dev/$dir_name, installation aborted."
    fi
    if ! runcmdagain /bin/chown $dir_owner:$dir_group $update_dev/$dir_name; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: Failed to set owner/group on directory: $update_dev/$dir_name, installation aborted."
    fi
    echo -e "DONE"
done <install_file_map
if [ -z "$first" ]; then
    echo -e "NONE";
fi

#===============================================================================================================
#  Based on the install_file_map, copy files to the specified filesystem. Set mode, owner and group on the file.
#  Skip any file that is not for this board number.
#===============================================================================================================
unset first
echo "Installing files in $update_dev.  " | awk '{printf "%-62s", $0}'
while read src_fname targ_fname src_fsize targ_fmode targ_fowner targ_fgroup targ_file_hw; do
    #===========================================================================================================
    #  Parse values from map file line.
    #===========================================================================================================
    if [ "$src_fname" = "DIRECTORY" -o "$src_fname" = "SYMLINK" ]; then
        continue
    fi
    targ=$targ_fname
    targ_fname=$update_dev/$targ_fname
    base_targ=`/usr/bin/basename $targ_fname`
    targ_path=`/usr/bin/dirname $targ_fname`

    #===========================================================================================================
    #  Skip file installation if the file is to be installed only on specific board model numbers and this
    #  board is not one of the specified boards.
    #===========================================================================================================
    if [ -n "$targ_file_hw" ]; then
        if ! /bin/echo $targ_file_hw | /bin/egrep -q "^$board_model_number | $board_model_number | $board_model_number$"; then
            log $LOG "Skipping file, not for this board model: $targ_fname."
            continue;
        fi
    fi

    if [ -z "$first" ]; then
        first=1
        echo -e "";
    fi
    echo "  $targ   " | awk '{printf "%-62s", $0}'

    #===========================================================================================================
    #  If file format (bzipped or not) in temp is not the same as installed file, bunzip2 the file. Compare the
    #  file to that in the flash file system, skip if identical. Copy the file to a temp file in the flash file system.
    #===========================================================================================================
    if ! echo $src_fname | /bin/egrep -qs ".bz2$"; then
        if echo $base_targ | /bin/egrep -qs ".bz2$"; then
            if ! runcmdagain /usr/bin/bunzip2 -f $src_fname; then
                echo -e "FAILED"
                error_exit $LOG 1 "Package Install: Failed to bunzip2 file: $src_fname, installation aborted.";
            fi
            src_fname=`echo $src_fname | /bin/sed "s/\.bz2$//;"`
        fi
    fi
    log $LOG "Installing file: $targ_fname, $targ_fmode, $targ_fowner, $targ_fgroup."
    if ! runcmdagain /bin/mkdir -p -m 775 "$targ_path"; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: Failed to create directory: $targ_path, installation aborted."
    fi
    if [ "$src_fname" != "rootfs.tar.bz2" ]; then
        runcmdagain /bin/cp -f $src_fname $targ_fname
    fi
    if [ "$?" != "0" ]; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: Failed to copy file: $src_fname --> $targ_fname, installation aborted.";
    fi

    #===========================================================================================================
    #  Set mode, owner and group on temp file in flash filesystem and move into place.
    #===========================================================================================================
    if ! runcmdagain /bin/chmod $targ_fmode $targ_fname; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: Failed to set mode on file: $src_fname --> $targ_fname, installation aborted.";
    fi
    if ! runcmdagain /bin/chown $targ_fowner:$targ_fgroup $targ_fname; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: Failed to set owner/group on file: $src_fname --> $targ_fname, installation aborted.";
    fi
    echo -e "DONE"
done <install_file_map
if [ -z "$first" ]; then
    echo -e "NONE";
fi

#===============================================================================================================
#  If the default factory options file is not present, install it.
#===============================================================================================================
echo "Install factory options file:  " | awk '{printf "%-62s", $0}'
if [ ! -f /sysopt/factory/falcon_factory.json ]; then
    if ! /bin/mkdir -p /sysopt/factory; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: FAILED to create /sysopt/factory directory, installation aborted."
    fi
    if ! /bin/cp $temp_dir/falcon_factory.json /sysopt/factory/falcon_factory.json; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: FAILED to install factory options file, installation aborted."
    fi
    echo -e "DONE"
else
    echo -e "SKIPPED"
fi

#===============================================================================================================
#  If the falcon options file is not present or is zero-length, create it by copying the factory default file.
#===============================================================================================================
echo "Install default options file:  " | awk '{printf "%-62s", $0}'
if [ ! -f /sysopt/config/sat_router/falcon.json ] || \
    [ `/bin/ls -s /sysopt/config/sat_router/falcon.json | /usr/bin/awk -F' ' '{print $1}'` -eq 0 ]; then
    if ! /bin/mkdir -p /sysopt/config/sat_router; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: FAILED to create /sysopt/sonfig/sat_router directory, installation aborted."
    fi
    if ! /bin/cp /sysopt/factory/falcon_factory.json /sysopt/config/sat_router/falcon.json; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: FAILED to install default options file, installation aborted."
    fi
    echo -e "DONE"
else
    echo -e "SKIPPED"
fi

#===============================================================================================================
#  Based on the install_file_map, create any symlinks specified.
#===============================================================================================================
unset first
echo "Create required sym-links:  " | awk '{printf "%-62s", $0}'
while read src_fname symlink_name separator targ_name rest; do
    if [ "$src_fname" != "SYMLINK" ]; then
        continue
    fi
    #===========================================================================================================
    #  Parse values from map file line.
    #===========================================================================================================
    symlink_dir_name=`dirname $symlink_name`
    symlink_base_name=`basename $symlink_name`
    targ_dir_name=`dirname $targ_name`
    targ_base_name=`basename $targ_name`

    #===========================================================================================================
    #  Create symlink.
    #===========================================================================================================
    if [ -z "$first" ]; then
        first=1
        echo -e "";
    fi
    echo "  $update_dev/$symlink_name:  " | awk '{printf "%-62s", $0}'
    log $LOG "Creating symlink: $update_dev/$symlink_name --> $targ_name."
    if ! echo "$targ_dir_name" | egrep -q "^/"; then
        if ! runcmdagain ln -sfn $targ_name $update_dev/$symlink_name; then
            echo -e "FAILED"
            error_exit $LOG 1 "Package Install: Failed to symlink: $update_dev/$symlink_name --> $targ_name, installation aborted."
        fi
    else
        CWD=`pwd`
        cd $symlink_dir_name
        if ! runcmdagain ln -sfn $targ_base_name $update_dev/$symlink_name; then
            echo -e "FAILED"
            error_exit $LOG 1 "Package Install: Failed to symlink: $update_dev/$symlink_name --> $targ_base_name, installation aborted."
        fi
        cd $CWD
    fi
    echo -e "DONE"
done <install_file_map
if [ -z "$first" ]; then
    echo -e "NONE";
fi

#===============================================================================================================
#  Create pkgList with this package name and the signed tarball name.
#===============================================================================================================
mkdir -p $update_dev/pkg
echo -e "iqseries_rootfs_urt_3.5.2.1-12131" >$update_dev/pkg/pkgList

#===============================================================================================================
#  Run postinstall script if one exists.
#===============================================================================================================
if [ -f "$temp_dir/postinstall" ]; then
    echo "Running package postinstall scriptlet:  " | awk '{printf "%-62s", $0}'
    log $LOG "Running package postinstall scriptlet."
    /bin/chmod 750 $temp_dir/postinstall
    $temp_dir/postinstall $temp_dir $update_dev $hardware_family
    rc=$?
    if [ "$rc" != "0" ]; then
        echo -e "FAILED"
        error_exit $LOG $rc "Package Install: Scriptlet postinstall failed, installation aborted."
    fi
    echo -e "DONE"
fi

#===============================================================================================================
#  Copy install_file_map to system package directory.
#===============================================================================================================
echo "Saving install_file_map:  " | awk '{printf "%-62s", $0}'
/bin/mkdir -p $update_dev/pkg/iqseries_rootfs_urt_3.5.2.1-12131
if ! /bin/cp $temp_dir/install_file_map $update_dev/pkg/iqseries_rootfs_urt_3.5.2.1-12131; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: Failed while saving the install_file_map file."
fi
echo -e "DONE"

#===============================================================================================================
#  Copy install.log to system package directory.
#===============================================================================================================
/bin/mkdir -p $update_dev/pkg/iqseries_rootfs_urt_3.5.2.1-12131
if ! /bin/cp $LOG $update_dev/pkg/iqseries_rootfs_urt_3.5.2.1-12131; then
    error_exit $LOG 1 "Package Install: Failed while saving the install.log file."
fi
if ! echo "Success" >$update_dev/pkg/iqseries_rootfs_urt_3.5.2.1-12131/status; then
    error_exit $LOG 1 "Package Install: Failed while updating installation status file."
fi

#===============================================================================================================
#  Erase the /common/pkgDb info for this device. Set status file to update complete and copy package metadata.
#===============================================================================================================
pname=`echo $update_dev | /usr/bin/awk -F'/' '{print $NF}'`
echo "Update /common/pkgDb/$partition_name:  " | awk '{printf "%-62s", $0}'
if ! /bin/rm -rf /common/pkgDb/$partition_name; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: Remove of /common/pkgDb/$partition_name failed, installation aborted."
fi
if ! /bin/mkdir -p /common/pkgDb/$partition_name; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: Creation of /common/pkgDb/$partition_name failed, installation aborted."
fi
if ! /bin/chown root:root /common/pkgDb/$partition_name; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: Failed to set owner/group on directory: /common/pkgDb/$partition_name, installation aborted."
fi
if ! /bin/chmod 755 /common/pkgDb/$partition_name; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: Failed to set mode on directory: /common/pkgDb/$partition_name, installation aborted."
fi

part_stat="Update complete, package status: "
while read pkg_name; do
    if [ -f $update_dev/pkg/$pkg_name/status ]; then
        pkg_stat=`head -1 $update_dev/pkg/$pkg_name/status`
    else
        pkg_stat="unknown"
    fi
    part_stat="$part_stat $pkg_name-$pkg_stat,"
done <$update_dev/pkg/pkgList

echo $part_stat >/common/pkgDb/$partition_name/status
if ! echo $part_stat >$update_dev/pkg/status; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: Failed to write file: /common/pkgDb/$partition_name/status, installation aborted."
fi
if ! /bin/chown root:root /common/pkgDb/$partition_name/status; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: Failed to set owner/group on file: /common/pkgDb/$partition_name/status, installation aborted."
fi
if ! /bin/chmod 644 /common/pkgDb/$partition_name/status; then
    echo -e "FAILED"
    error_exit $LOG 1 "Package Install: Failed to set mode on file: /common/pkgDb/$partition_name/status, installation aborted."
fi
CWD=`pwd`
if [ -d $update_dev/pkg ]; then
    cd $update_dev/pkg;
    if ! /bin/cp -af ./* /common/pkgDb/$partition_name/; then
        echo -e "FAILED"
        error_exit $LOG 1 "Package Install: Failed to copy package metadata for partiton: $partition_name, installation aborted."
    fi
    cd $CWD
fi
echo -e "DONE"

#===============================================================================================================
#  Report completion and clean up.
#===============================================================================================================
if ! /bin/sync; then
    error_exit $LOG 1 "Package Install: Failed while syncing filesystems."
fi
if ! /bin/sync; then
    error_exit $LOG 1 "Package Install: Failed while syncing filesystems again."
fi

restore_io_settings

#===============================================================================================================
#  Report final package status.
#===============================================================================================================
pkg_info=`/usr/sbin/pkgstat -l 2>/dev/null`
echo -e "$DTG -- Package installed status:" >>$LOG
echo -e "$pkg_info" >>$LOG

#===============================================================================================================
# report the memory status at the end of the upgrade
#===============================================================================================================
#NOTE: RAM and /tmp status may not reflect immediately, but log it though to analyze how low it's during upgrade
report_memory_status

log_and_report $LOG syslog.info "=========  Base Rootfs Package Installation script complete  ========="

#===============================================================================================================
#  Done
#===============================================================================================================
exit 0

