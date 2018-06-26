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
    printf "Please enter the ZFS dataset (e.g. zpool/jails: "
    read zfs_data_set
    printf "Please enter the mount point: "
    read zfs_jail_mount
    zfs create -o mountpoint=${zfs_jail_mount} ${zfs_data_set}
    cat << EOF > /etc/simple-jails.conf
zfs_data_set=${zfs_data_set}
zfs_jail_mount=${zfs_jail_mount}
EOF
}

sjail_fetch(){
    version="$1"
    echo "Setting up base for ${version}"
    source /etc/simple-jails.conf

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
        cp ${i} "${zfs_jail_mount}/templates/base-${version}/etc/${i}"
    done
}

sjail_update(){
    version="$1"
    echo "Updating ${version}"
    source /etc/simple-jails.conf
    env UNAME_r=${version} freebsd-update -b ${zfs_jail_mount}/templates/base-${version} fetch install
}

sjail_set_skel(){
    version="$1"
    echo "Setting up skeleton for ${version}"
    source /etc/simple-jails.conf
    if [ -e ${zfs_jail_mount}/templates/skeleton-${version} ]; then
        echo "Warning: skeleton for $version already created" 1>&2
        return 0
    fi

    zfs create -p ${zfs_data_set}/templates/skeleton-${version}
    to_create_dirs="usr/ports/distfiles home portsbuild"
    for i in $to_create_dirs; do
        mkdir -p "${zfs_jail_mount}/templates/skeleton-${version}/${i}"
    done

    to_move_dirs="etc usr/local tmp var root"
    for i in $to_move_dirs; do
        mv "${zfs_jail_mount}/templates/base-${version}/${i}" "${zfs_jail_mount}/templates/skeleton-${version}/${i}"
    done

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
}
