#!/bin/sh

set -eu

export KUBE_TYPE="${KUBE_TYPE:-master}"

[ "$KUBE_TYPE" = master -o "$KUBE_TYPE" = node ] \
	|| (echo "ERROR: KUBE_TYPE has unsupported value '$KUBE_TYPE', expected master or node" >&2; false)

kubeadm reset -f

# Make sure cgroup directory exists.
# This is a workaround because, within the container, /proc/1/cgroup points to the host path.
# See https://github.com/moby/moby/issues/34584
#CGROUP="$(grep -E '^1:name=' /proc/self/cgroup | sed -E 's/^1:name=([^:]+):/\1/')"
#mkdir -p "/sys/fs/cgroup/$CGROUP"
#export KUBELET_CUSTOM_ARGS="--cgroup-root=/$CGROUP --kube-reserved-cgroup=/$CGROUP/kube-reserved --kubelet-cgroups=/$CGROUP/kubelet"

# Add coredns (static ClusterIP) as first nameserver
# (on a real host with systemd-resolve enabled /etc/systemd/resolved.conf would be configured with '[Resolve]\nDNS=10.96.0.10')
RESOLVCONF="$(echo 'nameserver 10.96.0.10' && cat /etc/resolv.conf)"
echo "$RESOLVCONF" > /etc/resolv.conf

# Create the /dev/kvm node - required for kata-containers/qemu
if [ ! -e /dev/kvm ] && [ "${REQUIRE_KVM:-}" = true ]; then
	echo Creating /dev/kvm node
	mknod /dev/kvm c 10 $(grep '\<kvm\>' /proc/misc | cut -f 1 -d' ')   
fi

# Workaround for rook-ceph to see host's /dev/rbdX and /dev/nbdX devices.
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
#mount --make-shared /
#mount --make-shared /run
#mount --make-shared /lib/modules

mkdir -p /data/containers /var/lib/containers
mount --bind /data/containers /var/lib/containers

# Use CRI-O version from volume dir to compare with current
# to detect if storage needs to be wiped
#[ -f /var/lib/crio/version ] || (
#   # TODO: write version file if not exists
#	ln -s /var/lib/containers/crio-version /var/lib/crio/version
#)

rm -rf /var/lib/containers/node # remove old node state
rm -rf /var/lib/containers/storage/mounts /var/lib/containers/storage/overlay-containers

mkdir -p /var/lib/containers/node/kubelet-pods /var/lib/containers/node/logs /var/lib/kubelet/pods /var/log/pods
grep -E " /var/lib/kubelet/pods\s" /proc/mounts || mount --bind /var/lib/containers/node/kubelet-pods /var/lib/kubelet/pods
grep -E " /var/log/pods\s" /proc/mounts || mount --bind /var/lib/containers/node/logs /var/log/pods

mkdir -p /var/lib/containers/node/etcd /var/lib/etcd
grep -E " /var/lib/etcd\s" /proc/mounts || mount --bind /var/lib/containers/node/etcd /var/lib/etcd

grep -E " /run\s" /proc/mounts || mount -t tmpfs -o mode=1777 tmpfs /run

if [ "${KUBE_IMAGES_PRELOADED:-false}" = true -a ! -d /var/lib/containers-preloaded ]; then
	# Copy images from volume into image file system.
	# This is a workaround to commit a container that includes all images that where loaded into the volume previously
	crio &
	CRIO_PID=$!
	sleep 5
	crictl ps -q | xargs -r crictl stop
	crictl ps -qa | xargs -r crictl rm
	sleep 3
	kill $CRIO_PID
	sleep 3
	! kill -0 $CRIO_PID 2>/dev/null || (echo ERROR: crio did not terminate >&2; false)
	mount | grep -Eo " /data/containers/[^ ]+" | xargs -r umount
	rm -rf /data/containers/storage/overlay/*
	mkdir -p /var/lib/containers-preloaded
	cp -r /data/containers/storage/* /var/lib/containers-preloaded/
	sed -Ei 's/(additionalimagestores *= *\[.*)/\1 "\/var\/lib\/containers-preloaded"/' /etc/containers/storage.conf
	exit 0
fi

# Expose current env for kubeadm.service
env > /run/env

exec /usr/sbin/systemd
