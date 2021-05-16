#!/bin/sh

kubectl -n metallb-system get secret memberlist >/dev/null 2>&1 || \
	kubectl -n metallb-system create secret generic memberlist --from-literal=secretkey="`openssl rand 128 | openssl enc -A -base64`" >/dev/null
