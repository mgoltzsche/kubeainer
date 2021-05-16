#!/bin/sh

set -eu

echo Launching CRI-O
crio --root=/data &
CRIO_PID=$!
sleep 5

# TODO: fix preloaded images - coredns doesn't start properly and flannel cannot reach the apiserver when run from a preloaded image.
# TODO: also preload quay.io/coreos/flannel:v0.13.0 - doesn't work currently due to error:
#   failed to mount container k8s_install-cni_kube-flannel-ds-zm9k5_kube-system_a054f703-7f14-4461-82b5-7cc26554fe01_0(4b6a6c5a3fcb252e1f2de13b15a3c4b5dddca1fd369a5df53735d636fb7bbff4): error creating overlay mount to /var/lib/containers/storage/overlay/3e5cb8510ce29983cb1e63676a8e190cc60f7e3ac506b148aacd495e109a4392/merged: using mount program /usr/local/bin/fuse-overlayfs: fuse-overlayfs: cannot read upper dir: No such file or directory
K8S_IMAGES="$(kubeadm config images list --kubernetes-version=$K8S_VERSION)
rancher/local-path-provisioner:v0.0.19
"
for IMAGE in $K8S_IMAGES; do
	echo Pulling image $IMAGE
	crictl pull $IMAGE
done

echo Terminating CRI-O
kill $CRIO_PID
sleep 10
! kill -0 $CRIO_PID 2>/dev/null || (echo ERROR: crio did not terminate >&2; false)

find /data -type d | xargs chmod +rx
find /data -type f | xargs chmod +r
