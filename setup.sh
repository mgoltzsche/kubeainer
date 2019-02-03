#!/bin/sh

# See https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/

# TODO: Skip if already set up

# Validate env
[ ! -z "$KUBE_TOKEN" ] || (echo 'KUBE_TOKEN is not set' >&2; false) || exit 1

loadImages() {
	[ ! -f /preloaded-images.tar ] || docker load -i /preloaded-images.tar
}

# Init node
case "$KUBE_TYPE" in
	master)
		[ -f /etc/kubernetes/pki/ca.crt ] || (echo 'CA pub key /etc/kubernetes/pki/ca.crt does not exist' >&2; false) || exit 1
		[ -f /etc/kubernetes/pki/ca.key ] || (echo 'CA priv key /etc/kubernetes/pki/ca.key does not exist' >&2; false) || exit 1
		# ignoring missing bridge feature since it just doesn't show up within a network namespace due to a kernel bug but is functional
		set -x
		loadImages &&
		kubeadm init --token="$KUBE_TOKEN" --ignore-preflight-errors=FileContent--proc-sys-net-bridge-bridge-nf-call-iptables &&
		mkdir -p /root/.kube &&
		cp -f /etc/kubernetes/admin.conf /root/.kube/config &&

		# Untaint master node to schedule pods
		kubectl taint node $(hostname) node-role.kubernetes.io/master- &&

		# Install weave networking
		kubectl apply --wait=true --timeout=2m -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')" &&
		#kubectl wait -n kube-system --for condition=ready pods -l name=weave-net &&
		# Install kubernetes-dashboard
		#kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/master/aio/deploy/recommended/kubernetes-dashboard.yaml &&
		#kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/provider/baremetal/service-nodeport.yaml

		# Setup cert-manager issuer for namespace only (use namespaced issuer "ClusterIssuer" for single-tenant cluster)
		# See http://docs.cert-manager.io/en/release-0.6/getting-started/2-installing.html
		kubectl apply --wait=true --timeout=2m -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.6/deploy/manifests/cert-manager.yaml &&
		kubectl wait -n cert-manager --for condition=available --timeout 5m deployments/cert-manager-webhook deployments/cert-manager &&
		kubectl wait -n cert-manager --for condition=complete --timeout 5m jobs/cert-manager-webhook-ca-sync &&

		# Add ca as secret for ca-issuer (convert key since kubernetes tls secret only supports pkcs1 format)
		openssl rsa -in /etc/kubernetes/pki/ca.key -out /etc/kubernetes/pki/ca-rsa.key &&
		kubectl create secret tls cluster-ca-key-pair --cert=/etc/kubernetes/pki/ca.crt --key=/etc/kubernetes/pki/ca-rsa.key --namespace=cert-manager &&
		kubectl create secret tls ca-key-pair --cert=/etc/kubernetes/pki/ca.crt --key=/etc/kubernetes/pki/ca-rsa.key --namespace=default &&

		# Wait for cert-manager apiservice to become available (before applying issuer)
		kubectl wait --for condition=available --timeout 7m apiservice/v1beta1.admission.certmanager.k8s.io &&

		kubectl apply -f /etc/kubernetes/custom &&

		# Install helm
		# TODO: secure tiller access, see https://docs.helm.sh/using_helm/#best-practices-for-securing-helm-and-tiller
		helm init --wait --service-account tiller --override 'spec.template.spec.containers[0].command'='{/tiller,--storage=secret}' &&
			#--tiller-tls \
			#--tiller-tls-verify \
			#--tiller-tls-cert=cert.pem \
			#--tiller-tls-key=key.pem \
			#--tls-ca-cert=ca.pem
		helm repo update &&

		# Install Jenkins (see https://github.com/helm/charts/tree/master/stable/jenkins)
		helm install --name jenkins stable/jenkins --set Master.ServiceType=ClusterIP,Master.HostName=jenkins.algorythm.de,rbac.install=true,rbac.serviceAccountName=jenkins,Agent.Enabled=true,Persistence.Size=1Gi,Persistence.StorageClass=local-storage
	;;
	node)
		[ ! -z "$KUBE_MASTER" ] || (echo 'KUBE_MASTER is not set' >&2; false) || exit 1
		[ ! -z "$KUBE_CA_CERT_HASH" ] || (echo 'KUBE_CA_CERT_HASH is not set' >&2; false) || exit 1
		set -x
		loadImages &&
		mkdir -p /persistent-volumes/jenkins &&
		kubeadm join "$KUBE_MASTER" --token="$KUBE_TOKEN" --discovery-token-ca-cert-hash="$KUBE_CA_CERT_HASH" --ignore-preflight-errors=FileContent--proc-sys-net-bridge-bridge-nf-call-iptables
	;;
	*)
		echo "Unknown KUBE_TYPE value '$KUBE_TYPE'" >&2
		exit 1
	;;
esac
