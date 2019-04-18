#!/bin/sh

# Expose current env for kubeadm.service
env > /run/env &&

CEPH_MAX_RBD_DEVICES=${CEPH_MAX_RBD_DEVICES:-50}

# Fix mounts
mount --make-shared / &&
mount --make-shared /run &&
mount --make-shared /lib/modules || exit 1

# Provides $CEPH_MAX_RBD_DEVICES rbd device slots as symlinks to host's /dev.
# Host's /dev cannot be mounted into container's /dev directly since it
# causes conflicts/weird behaviour.
i=0
while [ $i -lt "$CEPH_MAX_RBD_DEVICES" ]; do
	ln -s /host/dev/rbd$i /dev/rbd$i &&
	i=$(expr $i + 1) || exit 1
done

#mkdir /dev-orig &&
#mount --rbind /dev /dev-orig &&
#mount --rbind /host/dev /dev &&
#ls /dev-orig | xargs -n1 -I{} mount --rbind /dev-orig/{} /dev/{}

mkdir -p /var/lib/docker/pods /var/lib/kubelet/pods &&
(grep -E "/var/lib/kubelet/pods\s" /proc/mounts || mount --bind /var/lib/docker/pods /var/lib/kubelet/pods) &&
mkdir -p /var/lib/docker/logs /var/log/pods &&
(grep -E "/var/log/pods\s" /proc/mounts || mount --bind /var/lib/docker/logs /var/log/pods) &&


exec /usr/sbin/systemd --unit=multi-user.target
