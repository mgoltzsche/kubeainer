#!/bin/bash

set -eu

# Make CoreDNS forward requests to the bind9 that is fed by external-dns

KUBE_MASTER_IP="$(cat /secrets/kube.masterip)"

COREFILE="$(kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | sed -E "s/ forward \. [^ ]+ / forward . $KUBE_MASTER_IP /")"

kubectl -n kube-system create cm coredns --from-literal=Corefile="$COREFILE" --dry-run=client -o yaml | kubectl replace -f -
