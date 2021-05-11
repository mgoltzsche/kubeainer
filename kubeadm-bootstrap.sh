#!/bin/sh

# See https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/

# TODO: Skip if already set up

set -e

SECRETS_DIR=/secrets
KUBE_TOKEN_FILE=$SECRETS_DIR/kube.token
KUBE_MASTER_IP_FILE=$SECRETS_DIR/kube.masterip
KUBE_CA_HASH_FILE=$SECRETS_DIR/kube.cahash

initMaster() {
	initCA
	KUBE_TOKEN="$(writeAtomicFile $KUBE_TOKEN_FILE kubeadm token generate)"
	KUBE_MASTER_IP="$(writeAtomicFile $KUBE_MASTER_IP_FILE getPublicIP)"
	echo Initializing Kubernetes $KUBERNETES_VERSION master
	set -x
	# ignoring missing bridge feature since it just doesn't show up within a network namespace due to a kernel bug but is functional
	# see https://github.com/cri-o/cri-o/blob/master/tutorials/kubeadm.md
	# TODO: move apiserver cgroup below container's cgroup as well:
	# --resource-container option, e.g. as in https://github.com/kubernetes-retired/kubeadm-dind-cluster/blob/master/image/kubeadm.conf.1.13.tmpl
	kubeadm init --token="$KUBE_TOKEN" \
		--cri-socket "/var/run/crio/crio.sock" \
		--pod-network-cidr=10.244.0.0/16 \
		--kubernetes-version=$K8S_VERSION \
		--ignore-preflight-errors=FileContent--proc-sys-net-bridge-bridge-nf-call-iptables \
		--ignore-preflight-errors Swap \
		--ignore-preflight-errors SystemVerification
	mkdir -p /root/.kube /output
	cp -f /etc/kubernetes/admin.conf /root/.kube/config
	cp -f /etc/kubernetes/admin.conf /output/kubeconfig.yaml
	chown $(stat -c '%u' /output) /output/kubeconfig.yaml
	enableCoreDNSPluginK8sExternal
	installApp flannel
	openssl rand -base64 128 > /etc/kubernetes/apps/metallb/secretkey
	#installApp metallb
	#installApp ingress-nginx
	#installApp local-path-provisioner
	#installApp external-dns
	#installApp cert-manager
	#installApp kata-runtimeclass

	# Untaint master node to schedule pods
	kubectl taint node "$(cat /etc/hostname)" node-role.kubernetes.io/master-
}

initNode() {
	[ -d $SECRETS_DIR ] || (echo ERROR: the directory $SECRETS_DIR does not exist but needs to be mounted into all node containers >&2; false)
	KUBE_CA_HASH="$(waitForFile $KUBE_CA_HASH_FILE)"
	KUBE_TOKEN="$(waitForFile $KUBE_TOKEN_FILE)"
	KUBE_MASTER_IP="$(waitForFile $KUBE_MASTER_IP_FILE)"
	KUBE_MASTER="$KUBE_MASTER_IP:6443"
	set -x
	kubeadm join "$KUBE_MASTER" --token="$KUBE_TOKEN" --discovery-token-ca-cert-hash="$KUBE_CA_HASH" \
		--cri-socket "/var/run/crio/crio.sock" \
		--ignore-preflight-errors=FileContent--proc-sys-net-bridge-bridge-nf-call-iptables \
		--ignore-preflight-errors Swap \
		--ignore-preflight-errors SystemVerification
}

# Args: APP_NAME
installApp() {
	kubectl apply -k "/etc/kubernetes/apps/$1"
}

initCA() {
	([ -f $SECRETS_DIR/ca.crt ] && [ -f $SECRETS_DIR/ca.key ]) || (
		mkdir -p $SECRETS_DIR &&
		rm -f $SECRETS_DIR/ca.crt $SECRETS_DIR/ca.key $KUBE_CA_HASH_FILE &&
		openssl req -x509 -nodes -newkey rsa:2048 -subj "/CN=kube-fake-ca" \
			-config /etc/ssl/ca.cnf -extensions v3_ca \
			-keyout $SECRETS_DIR/ca.key -out $SECRETS_DIR/ca.crt
	)
	mkdir -p /etc/kubernetes/pki
	cp -f $SECRETS_DIR/ca.key /etc/kubernetes/pki/ca.key
	cp -f $SECRETS_DIR/ca.crt /etc/kubernetes/pki/ca.crt
	writeAtomicFile $KUBE_CA_HASH_FILE hashCA >/dev/null
}

hashCA() {
	echo sha256:$(openssl x509 -in $SECRETS_DIR/ca.crt -noout -pubkey | openssl rsa -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)
}

# Args: FILE COMMAND
writeAtomicFile() {
	FILE="$1"
	shift
	[ -f $FILE ] || (
		mkdir -p $(dirname $FILE)
		TMPFILE=$(mktemp -p $(dirname $FILE)) &&
		"$@" > $TMPFILE &&
		mv $TMPFILE $FILE
		STATUS=$?
		rm -f $TMPFILE
		exit $STATUS
	)
	cat $FILE
}

getPublicIP() {
	ip -4 route get 8.8.8.8 | awk {'print $7'} | tr -d '\n'
}

# Args: FILE
waitForFile() {
	cat $1 2>/dev/null && return 0 || true
	echo Waiting for $1 to be written by master
	for i in $(seq 0 60); do
		sleep 1
		cat $1 2>/dev/null && return 0 || true
	done
	echo ERROR: Timed out waiting for $1 to be written by master >&2
	return 1
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
