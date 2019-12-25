#!/bin/sh

#
# This script starts the kubelet with --cgroup-root set to the current
# container's cgroup
#

set -e

CGROUP_ROOT="$(grep -E '[0-9]+:pids:' /proc/1/cgroup | cut -d: -f3)"
echo "Starting kubelet with cgroup root $CGROUP_ROOT" >&2

exec /opt/bin/kubelet \
	--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \
	--kubeconfig=/etc/kubernetes/kubelet.conf \
	--config=/var/lib/kubelet/config.yaml \
	--feature-gates=AllAlpha=false,RunAsGroup=true \
	--container-runtime=remote \
	--cgroup-driver=cgroupfs \
	--cgroup-root=/ \
	--kube-reserved-cgroup=$CGROUP_ROOT/kube-reserved \
	--kubelet-cgroups=$CGROUP_ROOT/kubelet \
	--container-runtime-endpoint=unix:///var/run/crio/crio.sock \
	--runtime-request-timeout=5m
# --cgroups-per-qos=false --enforce-node-allocatable=
