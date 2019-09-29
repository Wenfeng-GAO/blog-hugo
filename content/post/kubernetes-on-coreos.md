---
title: "Kubernetes on Coreos"
date: 2017-06-13T18:22:48+08:00
tags: ["kubernetes", "coreos", "docker"]
---

>Kubernetes is an open-source system for automating deployment, scaling, and management of containerized applications.

I just follow the guide of [CoreOS + Kubernetes Step By Step](https://coreos.com/kubernetes/docs/latest/getting-started.html)
to deploy [Kubernetes](http://kubernetes.io/) cluster on CoreOS.

Although this guide is detailed, there's still something that will cause
misunderstanding and should be paid close attention to. So this post is to
help you better follow the guide and setup Kubernetes.

First of all, according to [CoreOS cluster architectures](https://coreos.com/os/docs/latest/cluster-architectures.html),
the [CoreOS + Kubernetes Step By Step](https://coreos.com/kubernetes/docs/latest/getting-started.html)
guide is for *Easy development/testing cluster* or *Production cluster with central services*,
however, what I have is a *Small cluster* which was set up in the way
[Setup CoreOS Cluster with Static IPs](http://wenfeng-gao.github.io/2016/06/08/setup-coreos-cluster-with-static-ip.html),
that will make some difference to *ETCD_ENDPOINTS* environment variable.

### ETCD_ENDPOINTS
For each node, the *ETCD_ENDPOINTS* is `http://<node-routable-ip>:2379`. Don't
forget `http://`, it won't work without this token.

### gcr.io
If you're in China, thanks to the GFW service, you're not able to connect
*gcr.io* to download `gcr.io/google_containers/pause` image. So maybe you need
proxy for Docker.

So add a `unit` in your `cloud-config` file.

    - name: docker.service
      drop-ins:
        - name: 20-http-proxy.conf
          content: |
            [Service]
            Environment="HTTP_PROXY=http://www-proxy.ericsson.se:8080"
            Environment="HTTPS_PROXY=http://www-proxy.ericsson.se:8080"
      command: restart

Change `http://www-proxy.ericsson.se:8080` to your own proxy server url.


### journalctl
Sometimes the *active* status of `systemctl status` won't indicate everything
goes well, you may need

		sudo journalctl -f -t <some-service>

or

		sudo journalctl -f -u <some-service>

or just

		sudo journalctl -ex

These commands will help you find what's going wrong, and in most cases, you
just need to be **patient**, because downloading takes time specially the first
time you deploy.

Hope this helps.

