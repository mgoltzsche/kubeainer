#!/bin/sh

# See https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/

# TODO: Skip if already set up

set -e

# Validate env
[ ! -z "$KUBE_TOKEN" ] || (echo 'KUBE_TOKEN is not set' >&2; false)

loadImages() {
	[ ! -f /preloaded/images.tar ] || docker load -i /preloaded/images.tar
}

initMaster() {
	[ -f /etc/kubernetes/pki/ca.crt ] || (echo 'CA pub key /etc/kubernetes/pki/ca.crt does not exist' >&2; false)
	[ -f /etc/kubernetes/pki/ca.key ] || (echo 'CA priv key /etc/kubernetes/pki/ca.key does not exist' >&2; false)
	# ignoring missing bridge feature since it just doesn't show up within a network namespace due to a kernel bug but is functional
	set -x
	loadImages
	[ "$K8S_VERSION" ] || (echo 'K8S_VERSION not set' >&2; false) || exit 1
	# see https://github.com/cri-o/cri-o/blob/master/tutorials/kubeadm.md
	# TODO: move apiserver cgroup below container's cgroup as well:
	# --resource-container option, e.g. as in https://github.com/kubernetes-retired/kubeadm-dind-cluster/blob/master/image/kubeadm.conf.1.13.tmpl
	kubeadm init --token="$KUBE_TOKEN" \
		--cri-socket "/var/run/crio/crio.sock" \
		--pod-network-cidr=10.244.0.0/16 \
		--kubernetes-version=$K8S_VERSION \
		--ignore-preflight-errors=FileContent--proc-sys-net-bridge-bridge-nf-call-iptables
	mkdir -p /root/.kube /output
	cp -f /etc/kubernetes/admin.conf /root/.kube/config
	cp -f /etc/kubernetes/admin.conf /output/kubeconfig.yaml
	chown $(stat -c '%u' /output) /output/kubeconfig.yaml
	enableCoreDNSPluginK8sExternal
	installAddon flannel
	openssl rand -base64 128 > /etc/kubernetes/addons/metallb/secretkey
	installAddon metallb
	installAddon ingress-nginx
	installAddon local-path-provisioner
	installAddon external-dns

	# Untaint master node to schedule pods
	kubectl taint node "$(cat /etc/hostname)" node-role.kubernetes.io/master-
}

initNode() {
	[ ! -z "$KUBE_MASTER" ] || (echo 'KUBE_MASTER is not set' >&2; false)
	[ ! -z "$KUBE_CA_CERT_HASH" ] || (echo 'KUBE_CA_CERT_HASH is not set' >&2; false)
	set -x
	loadImages
	kubeadm join "$KUBE_MASTER" --token="$KUBE_TOKEN" --discovery-token-ca-cert-hash="$KUBE_CA_CERT_HASH" \
		--cri-socket "/var/run/crio/crio.sock" \
		--ignore-preflight-errors=FileContent--proc-sys-net-bridge-bridge-nf-call-iptables
}

# Args: ADDON_NAME
installAddon() {
	kubectl apply -k "/etc/kubernetes/addons/$1"
}

# Enables k8s_external coredns plugin to provide access to Services of type LoadBalancer under an external zone within the cluster and on nodes (required for e.g. registry)
enableCoreDNSPluginK8sExternal() {
	# original Corefile with k8s_external plugin enabled.
	# see https://github.com/coredns/coredns/tree/master/plugin/k8s_external
	kubectl apply -f - <<-EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        k8s_external svc.example.org
        prometheus :9153
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
	EOF
}



# Init node
case "$KUBE_TYPE" in
	master)
		initMaster
	;;
	node)
		initNode
	;;
	*)
		echo "Unknown KUBE_TYPE value '$KUBE_TYPE'" >&2
		exit 1
	;;
esac
