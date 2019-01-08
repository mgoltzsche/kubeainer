docker run -d \
    --net=host \
    k8s.gcr.io/etcd:3.1.12 \
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
    -v `pwd`/conf:/etc/kubernetes \
    k8s.gcr.io/hyperkube:v1.10.12 \
    /hyperkube kubelet \
		--containerized \
		--v=2 \
		--enable_server \
		--hostname_override=127.0.0.1 \
		--address=0.0.0.0 \
		--register-node \
		--config=/etc/kubernetes/config.yml

#-v `pwd`/conf/config.yml:/etc/kubernetes/config.yml \
