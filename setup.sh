#!/bin/sh

# Skip if already set up
[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ] && exit 0

# Validate env
[ ! -z "$KUBE_TOKEN" ] || (echo 'KUBE_TOKEN is not set' >&2; false) || exit 1

# Init node
case "$KUBE_TYPE" in
	master)
		[ -f /etc/kubernetes/pki/ca.crt ] || (echo 'CA pub key /etc/kubernetes/pki/ca.crt does not exist' >&2; false) || exit 1
		[ -f /etc/kubernetes/pki/ca.key ] || (echo 'CA priv key /etc/kubernetes/pki/ca.key does not exist' >&2; false) || exit 1
		# ignoring missing bridge feature since it just doesn't show up within a network namespace due to a kernel bug but is functional
		kubeadm init --token="$KUBE_TOKEN" --ignore-preflight-errors=FileContent--proc-sys-net-bridge-bridge-nf-call-iptables &&
		mkdir -p /root/.kube &&
		cp -f /etc/kubernetes/admin.conf /root/.kube/config &&
		# Install weave networking
		kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')" &&
		# Install kubernetes-dashboard
		kubectl create -f https://raw.githubusercontent.com/kubernetes/dashboard/master/aio/deploy/recommended/kubernetes-dashboard.yaml
	;;
	node)
		[ ! -z "$KUBE_MASTER" ] || (echo 'KUBE_MASTER is not set' >&2; false) || exit 1
		[ ! -z "$KUBE_CA_CERT_HASH" ] || (echo 'KUBE_CA_CERT_HASH is not set' >&2; false) || exit 1
		kubeadm join "$KUBE_MASTER" --token="$KUBE_TOKEN" --discovery-token-ca-cert-hash="$KUBE_CA_CERT_HASH" --ignore-preflight-errors=FileContent--proc-sys-net-bridge-bridge-nf-call-iptables
	;;
	*)
		echo "Unknown KUBE_TYPE value '$KUBE_TYPE'" >&2
		exit 1
	;;
esac
