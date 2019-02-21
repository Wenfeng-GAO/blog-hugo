---
title: "A Ping Question"
date: 2017-07-04T18:22:56+08:00
tags: ["network"]
---

Recently, I focus on OpenStack things where an interesting network question
comes out: **If a host machine has multiple network interfaces, is it possible to
ping all of them from another host?**

To be clearer, we assume that *Host A* has a unique network interface
192.168.11.0/24, *Host B* has 2 interfaces: `192.168.125.0/24` and `192.168.126.0/24`.
Meanwhile, the 3 interfaces are connected by a router, as the graph illustrated.

![2hosts](http://pn9ta8hbk.bkt.clouddn.com/2hosts.png)

If we look at the routing table of *Host B*, we'll find something like

```shell
[root@eta-bmc2 ~]# route -n
Kernel IP routing table
Destination     Gateway         Genmask         Flags Metric Ref    Use Iface
192.168.128.0   0.0.0.0         255.255.255.0   U     0      0        0 eth3
192.168.125.0   0.0.0.0         255.255.255.0   U     0      0        0 eth0
192.168.126.0   0.0.0.0         255.255.255.0   U     0      0        0 eth2
192.168.127.0   0.0.0.0         255.255.255.0   U     0      0        0 eth1
0.0.0.0         192.168.125.1   0.0.0.0         UG    0      0        0 eth0
```

If we ping from *Host B* to *Host A*, *Host B* looks up its routing table and find
no specific rools for destination `192.168.11.0/24`, so it will go via gateway
`192.168.125.1`.

```shell
[root@eta-bmc2 ~]# tracepath 192.168.11.20
 1:  192.168.125.1 (192.168.125.1)                          1.437ms
 2:  testagent (192.168.11.20)                              3.174ms reached
     Resume: pmtu 65535 hops 2 back 63
```

And if we ping from *Host A* to *Host B* of interface `192.168.125.0/24`, it goes
well. However, if we ping to *Host B*'s another interface, it will fail.

The reason is obvious, *Host A* send a packet to `192.168.126.92` and expect a
response from that destination. Unfortunately, *Host B* receives the packet but
can only response through `192.168.125.1`, which will never match for *Host A*.

So in this case, the answer is **NO**. But if *Host A*'s network interface is
in `192.168.126.0/24`, it can ping the 2 interfaces of *Host B*, or if *Host A*
also has multiple network interfaces, with proper routing table setting, it can
ping both 2 interfaces of *Host B* as well.

