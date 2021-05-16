#!/usr/bin/env bats

KUBE_MASTER_IP=10.23.0.2
SAMPLE_HOST=sample-app.kubeainer.example.org

# ARGS: SECONDS CMD...
retry() {
	SECONDS="$1"
	shift
	for i in $(seq 0 "$SECONDS"); do
		"$@" >/dev/null 2>&1 && break
		sleep 1
	done
	"$@"
}

# ARGS: INGRESS_NAME
getIngressLoadBalancerIP() {
	LB_IP="$(docker-compose exec -T kube-master kubectl get ingress "$1" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
	[ "$LB_IP" ] || (echo ingress $1 load balancer IP was not set >&2; false) || return 1
	echo "$LB_IP"
}

@test "launch single node compose cluster" {
	docker-compose up -d --scale kube-node=0
}

@test "wait for cluster to initialize" {
	docker-compose exec -T kube-master kubeainer install
}

@test "kubeconfig.yaml written to output directory" {
	[ -f kubeconfig.yaml ]
	(
		export KUBECONFIG=`pwd`/kubeconfig.yaml
		kubectl get nodes
	)
}

@test "install sample-app (pod network test)" {
	docker-compose exec -T kube-master kubeainer install-app sample-app
}

@test "install ingress-nginx" {
	docker-compose exec -T kube-master kubeainer install-app ingress-nginx
	docker-compose exec -T kube-master kubectl get ns ingress-nginx >/dev/null
}

@test "sample-app Ingress has master node IP assigned as load balancer IP" {
	LOADBALANCER_IP="$(retry 90 getIngressLoadBalancerIP sample-app-ingress)"
	echo "LOADBALANCER_IP=$LOADBALANCER_IP"
	[ "$LOADBALANCER_IP" = 10.23.0.2 ]
}

@test "sample-app Ingress is available" {
	docker-compose exec -T kube-master kubeainer retry 20 curl -fsS -H "Host: $SAMPLE_HOST" http://$KUBE_MASTER_IP/
	curl -fsS -H "Host: $SAMPLE_HOST" http://$KUBE_MASTER_IP/
}

@test "install external-dns" {
	docker-compose exec -T kube-master kubeainer install-app external-dns
}

@test "resolve sample-app Ingress hostname via master node IP (DNS test)" {
	retry 90 dig $SAMPLE_HOST @$KUBE_MASTER_IP | grep -Eq "^${SAMPLE_HOST}.\s+0\s+IN\s+A\s+[^ ]+$" \
		|| (dig $SAMPLE_HOST @$KUBE_MASTER_IP; false)
}

@test "resolve sample-app Ingress hostname within cluster (DNS test)" {
	SAMPLE_APP_POD=$(docker-compose exec -T kube-master kubectl get pod -o name | grep sample-app-client)
	retry 120 docker-compose exec -T kube-master kubectl exec $SAMPLE_APP_POD -- sh -c "wget -O /dev/null http://$SAMPLE_HOST"
}

@test "resolve known external hostname within cluster (DNS test)" {
	SAMPLE_APP_POD=$(docker-compose exec -T kube-master kubectl get pod -o name | grep sample-app-client)
	docker-compose exec -T kube-master kubectl exec $SAMPLE_APP_POD -- sh -c 'wget -O /dev/null https://docker.io'
}

@test "install local-path-provisioner and metallb" {
	docker-compose exec -T kube-master kubeainer install-app local-path-provisioner metallb
	docker-compose exec -T kube-master kubectl get ns local-path-storage >/dev/null
	docker-compose exec -T kube-master kubectl get ns metallb-system >/dev/null
}

# TODO: fix this: it fails every now and then because, during initialization of the new node,
# CoreDNS does not forward requests to external-dns apparently - which prevents the flannel image from being pulled on the new node.
# (in practice/dev cluster this can be avoided by not installing external-dns or installing it after all nodes are ready)
#@test "add node to cluster" {
#	docker-compose up -d --scale kube-node=1
#	docker-compose exec -T kube-node kubeainer install
#	NODE_NAME=$(docker-compose exec -T kube-node cat /etc/hostname | sed 's/\r//')
#	docker-compose exec -T kube-master kubectl get node "$NODE_NAME"
#}

@test "remove and recreate cluster with 2 nodes" {
	docker-compose rm -sf
	docker-compose up -d
	docker-compose exec -T kube-master kubeainer install
	docker-compose exec -T kube-node kubeainer install
}
