#!/bin/sh

set -e

# Add coredns (static ClusterIP) as first nameserver
# (on a real host with systemd-resolve enabled /etc/systemd/resolved.conf would be configured with '[Resolve]\nDNS=10.96.0.10')
RESOLVCONF="$(echo 'nameserver 10.96.0.10' && cat /etc/resolv.conf)"
echo "$RESOLVCONF" > /etc/resolv.conf

# Expose current env for kubeadm.service
env > /run/env

# Workaround to see host's /dev/rbdX and /dev/nbdX devices.
# Devices appear within the filesystem based on a system event
# which is not propagated to the container by the Linux kernel.
while true; do
	# Add missing devices
	FILTER='^(r|n)bd'
	lsblk --raw -a --output "NAME,MAJ:MIN" --noheadings | grep -E "$FILTER" | while read LINE; do
		DEV=/dev/$(echo $LINE | cut -d' ' -f1)
		MAJMIN=$(echo $LINE | cut -d' ' -f2)
		MAJ=$(echo $MAJMIN | cut -d: -f1)
		MIN=$(echo $MAJMIN | cut -d: -f2)
		[ -b "$DEV" ] || (set -x; mknod "$DEV" b $MAJ $MIN)
	done
	# Unregister removed devices
	find /dev -mindepth 1 -maxdepth 1 -type b | cut -d/ -f3 | grep -E "$FILTER" | sort > /tmp/devs-created
	lsblk --raw -a --output "NAME" --noheadings | grep -E "$FILTER" | sort > /tmp/devs-available
	for ORPHAN in $(comm -23 /tmp/devs-created /tmp/devs-available); do
		(set -x; rm /dev/$ORPHAN)
	done
	sleep 7
done &

set -ex

# Fix mounts
mount --make-shared /
#mount --make-shared /run
#mount --make-shared /lib/modules

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
