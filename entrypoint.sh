#!/bin/sh

# Expose current env for kubeadm.service
env > /run/env &&

# Setup mounts
mount --make-shared / &&
mkdir -p /var/lib/docker/pods /var/lib/kubelet/pods &&
(grep -E "/var/lib/kubelet/pods\s" /proc/mounts || mount --bind /var/lib/docker/pods /var/lib/kubelet/pods) &&
mkdir -p /var/lib/docker/logs /var/log/pods &&
(grep -E "/var/log/pods\s" /proc/mounts || mount --bind /var/lib/docker/logs /var/log/pods) &&


exec /usr/sbin/systemd --unit=multi-user.target
