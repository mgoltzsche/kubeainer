Kubeainer ![GitHub workflow badge](https://github.com/mgoltzsche/kubeainer/workflows/Semantic%20release/badge.svg)
=

A [Kubernetes](https://github.com/kubernetes/kubernetes) container image and [Docker Compose](https://docs.docker.com/compose/compose-file/compose-file-v3/) project to spin up a local cluster for development and experimentation purposes.  

It uses upstream Kubernetes as well as [CRI-O](https://github.com/cri-o/cri-o) and initializes the cluster using [kubeadm](https://github.com/kubernetes/kubeadm).

## Build and run from source

Clone the repo, build and run the container:
```sh
git clone https://github.com/mgoltzsche/kubeainer.git
make apps image compose-up
```
_Set the `NODES` parameter to scale._

## Usage

### Docker

Run a single-node cluster:
```sh
docker run -d --name mykube --privileged -v "`pwd`:/output" mgoltzsche/kubeainer:latest
```

Wait for the cluster to initialize:
```sh
docker exec mykube kubeainer install
export KUBECONFIG="`pwd`/kubeconfig.yaml
```

Complete example with ingress:
```sh
$ docker run -d --name mykube --privileged -p 80:80 -v "`pwd`:/output" mgoltzsche/kubeainer:latest
$ docker exec mykube kubeainer install ingress-nginx sample-app
$ docker exec mykube kubeainer retry 90 curl -fsS -H 'Host: sample-app.kubeainer.example.org' http://localhost
$ curl -fsS -H 'Host: sample-app.kubeainer.example.org' http://localhost
```

### Docker Compose

Run a single-node cluster:
```sh
docker-compose up -d --scale kube-node=0
```
_You can run a multi-node cluster by scaling the `kube-node` service._  

Wait for the cluster to initialize:
```sh
docker-compose exec -T kube-master kubeainer install
```

Apps can be installed by running e.g.:
```sh
docker-compose exec -T kube-master kubeainer install local-path-provisioner ingress-nginx cert-manager metallb external-dns
```
_Apps are kustomizations within the `/etc/kubeainer/apps` directory within the container._

Once the cluster is initialized the Kubernetes client configuration is written to `$PWD/kubeconfig.yaml` (`$PWD` is the compose directory) and can be used as follows:
```sh
export KUBECONFIG=$PWD/kubeconfig.yaml
```

## Init processes

```
entrypoint.sh
└── exec systemd
    ├── crio
    ├── kubelet
    └── kubeadm-bootstrap.sh
        └── kubeadm
```
