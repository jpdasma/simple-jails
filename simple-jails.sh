#!/bin/sh
set -ue

FTP_FREEBSD=ftp://ftp.freebsd.org/pub/FreeBSD/releases/amd64/amd64

check_config_file(){
    if [ ! -e /etc/simple-jails.conf ]; then
        cat << EOF 1>&2
Error: /etc/simple-jails.conf is missing
Please execute "$0 init" first
EOF
        exit 1
    fi
}

sjail_init(){
    if [ -e /etc/simple-jails.conf ]; then
        echo "Error: /etc/simple-jails.conf already exists" 1>&2
        exit 1
    fi
    printf "Please enter the ZFS dataset (e.g. zpool/jails): "
    read zfs_data_set
    printf "Please enter the mount point: "
    read zfs_jail_mount
    zfs create -o mountpoint=${zfs_jail_mount} ${zfs_data_set}
    cat << EOF > /etc/simple-jails.conf
zfs_data_set=${zfs_data_set}
zfs_jail_mount=${zfs_jail_mount}
EOF
    printf "Do you want simple-jails to setup cloned_if? [y/N]: "
    read answer
    while true; do
        case "$answer" in
            y|Y)
                cat >> /etc/rc.conf <<EOF
cloned_if="lo1"
ipv4_addrs_lo1="192.168.0.1-254/24"
EOF
                service netif cloneup
                break
                ;;
            n|N)
                echo "You're on your own"
                break
                ;;
            *)
                echo "Please answer with either 'y' or 'n' (without quotes)"
                ;;
        esac
    done

    printf "Do you want an initial jails.conf? [y/N]: "
    read answer
    while true; do
        case "$answer" in
            y|Y)
                cat > /etc/jails.conf <<EOF
# Global settings applied to all jails

host.hostname = "\$name.domain.local";
path = "${zfs_jail_mount}/\$name";
mount.fstab = "${zfs_jail_mount}/\$name.fstab";

exec.start = "/bin/sh /etc/rc";
exec.stop = "/bin/sh /etc/rc.shutdown";
exec.clean;
mount.devfs;
EOF
                break
                ;;
            n|N)
                echo "You're on your own"
                break
                ;;
            *)
                echo "Please answer with either 'y' or 'n' (without quotes)"
                ;;
        esac
    done

}

sjail_fetch(){
    version="$1"
    echo "Setting up base for ${version}"
    . /etc/simple-jails.conf

    if [ -e ${zfs_jail_mount}/templates/base-${version} ]; then
        echo "Error: $version already fetched" 1>&2
        exit 1
    fi

    to_download='base.txz lib32.txz ports.txz'
    to_copy='/etc/resolv.conf /etc/localtime'

    for i in $to_download; do
        rm -f /tmp/${i} || true
        fetch ${FTP_FREEBSD}/${version}/${i} -o /tmp/${i}
        echo $i
    done

    zfs create -p ${zfs_data_set}/templates/base-${version}

    for i in $to_download; do
        tar -xvf /tmp/${i} -C "${zfs_jail_mount}/templates/base-${version}"
    done

    for i in $to_copy; do
        cp ${i} "${zfs_jail_mount}/templates/base-${version}${i}" || true
    done

    sjail_set_skel "$version"
}

sjail_update(){
    version="$1"
    echo "Updating ${version}"
    . /etc/simple-jails.conf
    env UNAME_r=${version} freebsd-update -b ${zfs_jail_mount}/templates/base-${version} fetch install
    env UNAME_r=${version} freebsd-update -b ${zfs_jail_mount}/templates/base-${version} IDS
}

sjail_set_skel(){
    version="$1"
    echo "Setting up skeleton for ${version}"
    . /etc/simple-jails.conf
    if [ -e ${zfs_jail_mount}/templates/skeleton-${version} ]; then
        echo "Warning: skeleton for $version already created" 1>&2
        return 0
    fi

    zfs create -p ${zfs_data_set}/templates/skeleton-${version}
    to_create_dirs="usr/ports/distfiles home portsbuild"
    for i in $to_create_dirs; do
        mkdir -p "${zfs_jail_mount}/templates/skeleton-${version}/${i}"
    done

    chflags noschg "${zfs_jail_mount}/templates/base-${version}/var/empty"
    to_move_dirs="etc usr/local tmp var root"
    for i in $to_move_dirs; do
        mv "${zfs_jail_mount}/templates/base-${version}/${i}" "${zfs_jail_mount}/templates/skeleton-${version}/${i}"
    done
    chflags schg "${zfs_jail_mount}/templates/skeleton-${version}/var/empty"

    current_dir=$(pwd)
    cd ${zfs_jail_mount}/templates/base-${version}
    mkdir skeleton
    to_symlink="etc home root tmp var" # usr/local usr/ports/distfiles
    for i in $to_symlink; do
        ln -s skeleton/${i} ${i}
    done

    # SPECIAL CASE START #
    cd usr       && ln -s ../skeleton/usr/local              local     && cd ..
    cd usr/ports && ln -s ../../skeleton/usr/ports/distfiles distfiles && cd ../../
    # SPECIAL CASE END #

    cd "${current_dir}"
    echo  "WRKDIRPREFIX?=  /skeleton/portbuild" >> ${zfs_jail_mount}/templates/skeleton-${version}/etc/make.conf
    zfs snapshot ${zfs_data_set}/templates/skeleton-${version}@skeleton
}

sjail_create_thinjail() {
    version="$1"
    jail_name="$2"
    echo "Setting up jail: $jail_name"
    . /etc/simple-jails.conf
    if [ ! -e ${zfs_jail_mount}/thinjails ]; then
        zfs create ${zfs_data_set}/thinjails
    fi

    if [ -e ${zfs_jail_mount}/thinjails/${jail_name} ]; then
        echo "Error: ${jail_name} already exists" 1>&2
        exit 1
    fi

    zfs clone ${zfs_data_set}/templates/skeleton-${version}@skeleton ${zfs_data_set}/thinjails/${jail_name}
    echo hostname=\"${jail_name}\" > ${zfs_jail_mount}/thinjails/${jail_name}/etc/rc.conf

    mkdir -p ${zfs_jail_mount}/${jail_name}
    cat <<EOF > ${zfs_jail_mount}/${jail_name}.fstab
${zfs_jail_mount}/templates/base-${version}	${zfs_jail_mount}/${jail_name}/ nullfs ro 0 0
${zfs_jail_mount}/thinjails/${jail_name}	${zfs_jail_mount}/${jail_name}/skeleton nullfs rw 0 0
EOF
}

sjail_delete_thinjail() {
    jail_name="$1"
    echo "Deleting jail: $jail_name"
    . /etc/simple-jails.conf
    if grep "jail_enable=\"YES\"" /etc/rc.conf >/dev/null 2>&1; then
        service jail stop "$jail_name" || true
    else
        service jail onestop "$jail_name" || true
    fi

    # SANITY CHECK
    if [ -e "${zfs_jail_mount}/thinjails/${jail_name}" ]; then
        zfs destroy "${zfs_data_set}/thinjails/${jail_name}"
    else
        echo "$jail_name" does not exists 1>&2 
        exit 1
    fi

    # SANITY CHECK
    if [ -z "$zfs_jail_mount" ]; then
        echo "Will not delete /${jail_name}" 1>&2
	exit 1
    elif [ -z "$jail_name" ]; then
        echo "Will not delete $zfs_jail_mount/" 1>&2
	exit 1
    else
        rm -rf ${zfs_jail_mount}/${jail_name}
        rm -rf ${zfs_jail_mount}/${jail_name}.fstab
    fi
}


usage() {
    cat <<EOF
Usage: `basename $0` COMMAND [args]

Commands:
    init                 Install initial config file (/etc/simple-jails.conf)
    fetch VERSION        Fetch and create base template for version VERSION
                         (e.g. 11.2-RELEASE)
    update VERSION       Apply freebsd-update on base template with version
                         VERSION. Can be done anytime.
    create VERSION NAME  Create thin jail NAME from base template with version
                         VERSION. Update /etc/jail.conf manually.
    delete Name          Delete thin jail NAME. Will stop if it currently
                         running.
EOF
    exit 0
}

command=$1; shift
case $command in
    "init")
        sjail_init
        ;;
    "fetch")
        sjail_fetch "$@"
        ;;
    "update")
        sjail_update "$@"
        ;;
    "create")
        sjail_create_thinjail "$@"
        ;;
    "delete")
        sjail_delete_thinjail "$@"
        ;;
    *)
        usage
        ;;
esac
