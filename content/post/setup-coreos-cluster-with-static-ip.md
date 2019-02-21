---
title: "Setup Coreos Cluster With Static Ip"
date: 2017-06-08T18:22:33+08:00
tags: ["coreos", "docker"]
---

We have talked about how to setup a CoreOS cluster in my previous post:
[Setup CoreOS Cluster Manually with VirtualBox](http://wenfeng-gao.github.io/2016/05/30/setup-coreos-cluster-in-virtualbox.html).
However, as we setup the cluster in VirtualBox, which uses DHCP as default,
the *etcd2* may not work when VM's IP changed.

So in this article I'll tell you how to upgrade your cluster and enable the
VMs use static IPs instead of DHCP.

### Setup Static IP
First of all, make sure your cluster node VM uses the *bridge* connection type
(as default), that will enable the connection between outer world, as we are not
going to set IP tables.

In each node VM, create file `static.network` in path `/etc/systemd/network/`,
if the directory doesn't exist, create one.

		[Match]
		Name=enp0s3

		[Network]
		DNS=150.236.34.180
		DNS=193.181.14.10
		DNS=150.236.34.181

		Address=150.236.224.100/24
		Gateway=150.236.224.1

- `Name` is your network interface, you may run `ifconfig` to check.
- Make sure your static IP Address is in the period of your host machine's network,
as we use *bridge* connection type.
- Make sure you have the right DNS, you may copy from `/etc/resolv.conf`

### Update ETCD2
We need to update *etcd2* as the IPs changed.

First, we need a new *discovery key*, so

		curl https://discovery.etcd.io/new?size=3

Then, just update to the new *discovery key* and new IP addresses.

Last and most important, we need remove several files to make our new *etcd2*
settings work.

		sudo rm -rf /run/systemd/system/etcd2.service.d/

		sudo rm -rf /var/lib/etcd2

### It's done
Do these updates on each node VM, and restart them on the same time. Then you'll
find you have a new CoreOS cluster with static IPs, enjoy!

