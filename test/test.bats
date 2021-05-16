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
	retry 20 curl -fsS -H "Host: $SAMPLE_HOST" http://$KUBE_MASTER_IP/
}

@test "install external-dns" {
	docker-compose exec -T kube-master kubeainer install-app external-dns
}

@test "resolve sample-app Ingress hostname via master node IP" {
	retry 90 dig $SAMPLE_HOST @$KUBE_MASTER_IP | grep -Eq "^${SAMPLE_HOST}.\s+0\s+IN\s+A\s+[^ ]+$" \
		|| (dig $SAMPLE_HOST @$KUBE_MASTER_IP; false)
}

#@test "resolve sample-app Ingress hostname within cluster (CoreDNS config verification)" {
# TODO: resolve external hostname within pod within the cluster - doesn't work yet
#}

@test "install local-path-provisioner and metallb" {
	docker-compose exec -T kube-master kubeainer install-app local-path-provisioner metallb
	docker-compose exec -T kube-master kubectl get ns local-path-storage >/dev/null
	docker-compose exec -T kube-master kubectl get ns metallb-system >/dev/null
}

# TODO: enable this - as long as external-dns is deployed beforehand node initialization may fail because external-dns may not be ready yet
#@test "add node to cluster" {
#	docker-compose up -d --scale kube-node=1
#	docker-compose exec -T kube-node kubeainer install
#	NODE_NAME=$(docker-compose exec -T kube-node cat /etc/hostname | sed 's/\r//')
#	docker-compose exec -T kube-master kubectl get node "$NODE_NAME"
#}
