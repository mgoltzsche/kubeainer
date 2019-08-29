#!/bin/sh

set -ex

# Expose current env for kubeadm.service
env > /run/env

CEPH_MAX_RBD_DEVICES=${CEPH_MAX_RBD_DEVICES:-50}

# Fix mounts
mount --make-shared /
#mount --make-shared /run
#mount --make-shared /lib/modules

# Provides $CEPH_MAX_RBD_DEVICES rbd device slots as symlinks to host's /dev.
# Host's /dev cannot be mounted into container's /dev directly since it
# causes conflicts/weird behaviour.
i=0
while [ $i -lt "$CEPH_MAX_RBD_DEVICES" ]; do
	ln -s /host/dev/rbd$i /dev/rbd$i
	i=$(expr $i + 1) || exit 1
done

# Use CRI-O version from volume dir to compare with current
# to detect if storage needs to be wiped
#[ -f /var/lib/crio/version ] || (
#   # TODO: write version file if not exists
#	ln -s /var/lib/containers/crio-version /var/lib/crio/version
#)

rm -rf /var/lib/containers/node # remove old node state
rm -rf /var/lib/containers/storage/mounts /var/lib/containers/storage/overlay-containers

mkdir -p /var/lib/containers/node/kubelet-pods /var/lib/containers/node/logs /var/lib/kubelet/pods /var/log/pods
grep -E "/var/lib/kubelet/pods\s" /proc/mounts || mount --bind /var/lib/containers/node/kubelet-pods /var/lib/kubelet/pods
grep -E "/var/log/pods\s" /proc/mounts || mount --bind /var/lib/containers/node/logs /var/log/pods

mkdir -p /var/lib/containers/node/etcd /var/lib/etcd
grep -E "/var/lib/etcd\s" /proc/mounts || mount --bind /var/lib/containers/node/etcd /var/lib/etcd

exec /usr/sbin/systemd --unit=multi-user.target
