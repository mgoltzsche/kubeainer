all: build run

build:
	docker build -f Dockerfile-centos -t local/kubernetes .

build-alpine:
	docker build -f Dockerfile-alpine -t local/kubernetes .

run:
	# Start a kubernetes node
	# HINT: Use oci systemd hooks, see https://developers.redhat.com/blog/2016/09/13/running-systemd-in-a-non-privileged-container/
	docker run -ti --privileged \
		-v /sys/fs/cgroup:/sys/fs/cgroup:ro \
		-v /sys/fs/cgroup/systemd:/sys/fs/cgroup/systemd:rw \
		-v /lib/modules:/lib/modules:ro \
		-v /boot:/boot:ro \
		-v /etc/machine-id:/etc/machine-id:ro \
		--tmpfs /run \
		--tmpfs /tmp \
		local/kubernetes

#-v /run:/run
#-v /etc/systemd:/etc/systemd
