# etcd, see for compatible version: https://github.com/kubernetes/kubernetes/blob/master/cluster/images/etcd/Makefile
docker run -d \
    --net=host \
    k8s.gcr.io/etcd:3.3.10 \
    /usr/local/bin/etcd \
		--initial-cluster-state=new \
		--initial-advertise-peer-urls='http://localhost:2379' \
        --initial-cluster='default=http://localhost:2379' \
        --initial-cluster-token='etcd-cluster' \
        --advertise-client-urls='http://localhost:2379' \
        --data-dir=/var/etcd/data

docker run \
	--privileged \
    --net=host \
    --pid=host \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /:/rootfs:ro \
    -v /var/lib/kubelet:/var/lib/kubelet:rw \
    -v /sys/fs/cgroup:/sys/fs/cgroup \
    -v `pwd`/conf/etc/kubernetes:/etc/kubernetes \
    -v `pwd`/conf/var/lib/kubelet/config.yaml:/var/lib/kubelet/config.yaml:ro \
    k8s.gcr.io/hyperkube:v1.13.1 \
    /hyperkube kubelet \
		--config=/var/lib/kubelet/config.yaml \
		--containerized \
		--v=2 \
		--enable_server \
		--hostname_override=127.0.0.1 \
		--address=0.0.0.0 \
		--register-node

#-v `pwd`/conf/config.yml:/etc/kubernetes/config.yml \
