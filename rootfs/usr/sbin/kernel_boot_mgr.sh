#!/bin/sh
#For IQ DT/200, the kernel is loaded from NOR flash by primary bootloader. To support multiple kernel booting, boot
#directory partition needs to be updated accordingly for primary bootloader to choose the right kernel to boot.
#This script checks current application partition and set the boot_dir partition according to the kernel and user
#partition mapping as follows assuming the kernel images have been flashed already.
#
#kernel-1 ---  factory application
#kernel-2 --   User1 application
#kernel-3 --   User2 application

BOOT_DIR_FILE=/common/boot_dir.bin
KERNEL_UPDATE_FILE=/common/kernel_update

log()
{
    DTG=`date "+%D-%R:%S"`
    echo -e "$DTG -- $@"
    logger "$@"
}

log_error_exit()
{
    local err_id="$1"
    shift
    DTG=`date "+%D-%R:%S"`
    echo -e "$DTG -- $@"
    logger -p user.err "$@"
    exit $err_id
}

activate_new_kernel()
{
    if [ ! -e "$KERNEL_UPDATE_FILE" ]; then
        log "no kernel update, skip activate"
        exit 0
    fi

    set_next_boot_kernel 'next'
    make_boot_dir_bin
    flash_boot_directory

    if ! /bin/rm -f "$KERNEL_UPDATE_FILE"; then
        log_error_exit 1 "FAILED to delete $KERNEL_UPDATE_FILE after activation."
    fi
}

get_boot_dir_dev()
{
    bootdir_chardev=$(awk 'BEGIN{FS="[\":\r\t\n ]+"} {if($4 ~ "boot-dir"){if($1 ~ /\/dev\/.+/) \
                      {print $1}else{print "/dev/"$1}}}' /proc/mtd 2>/dev/null)

    if [ -z "$bootdir_chardev" ]; then
        log_error_exit 1 "Package Install: FAILED to get the boot_dir character device from /proc/mtd, kernel switch aborted."
    fi
    if [ ! -c $bootdir_chardev ]; then
        log_error_exit 1 "Package Install: boot_dir character device $bootdir_chardev does not exist, kernel switch aborted."
    fi
}

#Primary boatloader can support multiple user entries. It's safer not assuming the user1 entry
#always in the second place.
get_user1_entry_offset()
{
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

    echo $(hexdump -s $((i*4+2)) -n 1 $bootdir_chardev | awk 'NR==1 {print $2}')
}

get_kernel_information()
{
    get_boot_dir_dev

    case "$(get_user1_entry_offset)" in
        004a) current_kernel="kernel-1"
            ;;
        008a) current_kernel="kernel-2"
            ;;
        00ca) current_kernel="kernel-3"
            ;;
           *) log_error_exit 1 "Package Install: invalid current_kernel, kernel switch aborted."
            ;;
    esac

    #check if user specifies the next kernel_partition
    #find the next user partition
    local next_user_partition=$(fw_printenv | awk -F "="  '($1=="fspart") {print $NF}')
    case "$next_user_partition" in
        factory) next_kernel="kernel-1"
            ;;
        active0) next_kernel="kernel-2"
            ;;
        active1) next_kernel="kernel-3"
            ;;
        *)
        log_error_exit 1 "invalid user partition number, kernel switch aborted."
        ;;
    esac
}

make_boot_dir_bin()
{
    #These are the four entries in boot_dir partition
    local number_version='\x03\x00\x00\x01' #number & version
    local factory_entry='\xfe\x00\x4a\x00'  #Factory entry
    local user1_entry                       #User1 entry
    local user2_entry='\xfc\x00\x4a\x00'    #User2 entry

    #Primary bootloader always reads user1_entry for kernel
    case "$next_kernel" in
        kernel-1) user1_entry='\xfd\x00\x4a\x00'
            ;;
        kernel-2) user1_entry='\xfd\x00\x8a\x00'
            ;;
        kernel-3) user1_entry='\xfd\x00\xca\x00'
            ;;
               *) log_error_exit 1 "invalid kernel partition number, kernel switch aborted."
            ;;
    esac

    printf "$number_version$factory_entry$user1_entry$user2_entry" > $BOOT_DIR_FILE
}

set_next_boot_kernel()
{
    case "$1" in
        "next") #use default next kernel
        ;;
        [1-3]) log "next kernel: kernel-$1, the default kernel: $next_kernel"
               next_kernel="kernel-$1"
        ;;
        *)
        log_error_exit 1 "invalid kernel partition number, kernel switch aborted."
        ;;
    esac

    if [ "$next_kernel" == "$current_kernel" ]; then
        log "next kernel is the same as the current kernel, no change needed"
        exit 0
    fi
}


flash_boot_directory()
{
    if [ -s "$BOOT_DIR_FILE" ]; then
        log "Updating boot_dir on $bootdir_chardev"
        if ! /usr/sbin/flashcp "$BOOT_DIR_FILE" $bootdir_chardev; then
            log_error_exit 1 "FAILED to update the boot_dir, kernel switch aborted."
        fi
        if ! /bin/rm -f "$BOOT_DIR_FILE"; then
            log_error_exit 1 "FAILED to delete $BOOT_DIR_FILE after flashing it."
        fi
    else
        log_error_exit 1 "no boot_dir_bin file, kernel switch aborted."
    fi
}

ARGC=$#

print_usage()
{
cat << EOF
Usage: switch_kernel.sh [-a] [-i] [-s partition] [-h]

-a activate after the kernel upgrade
-i kernel boot information
-s number set the next kernel to boot.
   next  -- default next kernel
   1  -- kernel-1
   2  -- kernel-2
   3  -- kernel-3
-h print this text
EOF
}

parse_args()
{
    while getopts "ais:h" option ;
    do
        case ${option} in
            a) activate_new_kernel
            ;;
            i) echo -e "current kernel: $current_kernel"
               echo -e "next kernel: $next_kernel"
            ;;
            s) set_next_boot_kernel "$OPTARG"
               make_boot_dir_bin
               flash_boot_directory
            ;;
            h) print_usage && exit 0
            ;;
            \?) echo -e "Invalid option: -$OPTARG" >&2
            ;;
        esac
    done
    shift $((OPTIND-1))
}

main()
{
    [ "$ARGC" -eq 0  ] && print_usage && exit 0
    get_kernel_information
	parse_args "$@"
}

main "$@"
