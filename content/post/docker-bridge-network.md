---
title: "浅谈Docker Bridge网络模式"
date: 2016-05-20T18:21:36+08:00
tags: ["docker", "network"]
---

本文将简单介绍一下Docker的3中网络模式，然后着重介绍**bridge**模式的数据传输过程，浅谈Docker容器与宿主机
之间，以及与外部世界的数据传输过程。

### Docker的3种网络模式

我们知道，当Docker Daemon启动时，会创建3种网络模式供Docker容器使用：**bridge**, **host** 和**none**模式。
可以通过 `docker network ls` 看到如下结果

```shell
docker@master:~$ docker network ls
NETWORK ID          NAME                DRIVER
9b7805f760e7        bridge              bridge
77a7c8decdc1        host                host
8a9285d7055e        none                null
```
其中**none** 将容器加入到一个没有网络接口的特殊网络栈，进入使用**none**网络的容器执行`ifconfig`会看到

```shell
root@0cb243cd1293:/# ifconfig
lo        Link encap:Local Loopback
          inet addr:127.0.0.1  Mask:255.0.0.0
          inet6 addr: ::1/128 Scope:Host
          UP LOOPBACK RUNNING  MTU:65536  Metric:1
          RX packets:0 errors:0 dropped:0 overruns:0 frame:0
          TX packets:0 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:0
          RX bytes:0 (0.0 B)  TX bytes:0 (0.0 B)
```

而**host**网络模式会将容器直接加到Docker宿主机的网络栈中，这样会是的数据传输更快速，但同时因为失去了隔离
的网络环境，容器可以直接更改和影响宿主机网络，增添了更过不安全的因素。

而最被广泛应用的就是**bridge**网络模式了，这也是Docker创建容器的默认网络模式。当运行Docker Daemon后，执行
`ifconfig`会发现多出了一个叫**docker0**的网络接口

```shell
docker@master:~$ ifconfig
docker0   Link encap:Ethernet  HWaddr 02:42:2B:AB:D8:A0
          inet addr:172.17.0.1  Bcast:0.0.0.0  Mask:255.255.0.0
          UP BROADCAST MULTICAST  MTU:1500  Metric:1
          RX packets:0 errors:0 dropped:0 overruns:0 frame:0
          TX packets:0 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:0
          RX bytes:0 (0.0 B)  TX bytes:0 (0.0 B)
```

这就是Docker Daemon为容器提供的隔离与宿主机网络栈的网络接口，只能被Docker容器所使用。
下面这张图展示了Docker的3中网络模式。
![Docker default networks](http://pn9ta8hbk.bkt.clouddn.com/docker-networks.png)

创建容器时，可以通过`--net`来指定容器使用哪种网络，例如`docker run -itd --net=host busybox`。

### 容器与Docker宿主机之间通信
通过**bridge**桥接模式，实现容器与宿主机间通信的根本在于[veth pair](http://www.opencloudblog.com/?p=66)技术。
可以再次参照上图。

1. 利用**veth pair**技术在宿主机上创建两个虚拟网络接口，**veth0** 和 **veth1**。而**veth pair**技术的特性可以保证
无论哪个接口接收到网络报文，都会将报文传输给另一方。
2. Docker Daemon将vth0添加到**docker0**网桥上，保证了宿主机的网络报文能够发给**veth0**，也就是能发给**veth1**。
3. Docker Daemon将**veth1**添加到容器所属的网络命名空间(namespaces)下，**veth1**在容器内部看来就是**eth0**。
一方面，宿主机发给**veth0**的网络报文能立刻被容器接收到，实现容器如宿主机间的网络连通；另一方面，Docker容器
单独使用**veth1**，实现容器与宿主机之间，以及容器与容器之间的网络隔离。

### 外部世界访问Docker容器
利用**veth pair**技术，实现了容器与宿主机之间的网络通信，但由于**docker0**与宿主机的**eth0**并不属于同一网段，
外部世界并不能直接访问Docker容器的内部服务。对此，Docker使用[NAT(Network Address Translation)](https://en.wikipedia.org/wiki/Network_address_translation)
的方式，将提供内部服务的端口(port0)与宿主机的某个接口(port1)进行绑定，如此一来，外部世界访问Docker容器
内部服务的流程为：

1. 外部世界访问宿主机的IP与端口号：**host-ip-addr:port1**
2. 宿主机接收到请求后，由于**DNAT**规则，会将**host-ip-addr:port1**替换为**docker-container-ip:port0**
3. 由于能够识别容器IP，宿主机将请求发给**veth pair**， 容器接收到请求并开始内部服务

这也是为什么当我们想要将容器的服务暴露给外部时，需要使用`-P`或者`-p host-port:container-port`来绑定映射端口。
例如`docker run -d -p 80:5000 training/webapp python app.py`。

### Docker容器访问外部世界
Docker容器访问外部世界会用到[IP forwarding](https://en.wikipedia.org/wiki/IP_forwarding)技术，具体流程为：

1. Docker容器向**outer-world-ip:port2**发起请求，Linux内核会自动为进程分配一个可用端口(**port3**)，如此请求源为
**docker-container-ip:port3**。
2. 请求通过**veth pair**到达**docker0**处，**docker0**网桥开启了**IP forwarding**功能，将请求发送至宿主机**eth0**处。
3. 宿主机处理请求时，使用**SNAT**规则，将源地址**docker-container-ip:port3**替换成了**host-ip-addr:port3**，并
将报文放给外界。
4. 值得注意的是，外部响应请求时，响应报文的目的地IP地址是宿主机地址，而宿主机转发给Docker容器时，并不是用
**DNAT**规则转换，应为容器绑定的端口是为了提供内部服务的，不能被占用，这里是用**iptables**的规则实现的，使得宿主机
上发往**docker0**网桥的报文，如果数据报所处的连接已经建立，则无条件接受，并转至原来的连接上，即回到Docker容器内部。

这就是**docker0**网络数据传输的简要流程分析，**docker0**是Docker使用中最基本、最常用的网络模式，了解它的传输过程
对配置更高级的网络环境也有帮助。


### 参考引用
本文除了引用已经给出的链接外，主要参考了**《Docker源码分析》(孙宏亮著 机械工业出版社)**一书，以及[Docker 官方文档](https://docs.docker.com/)
的网络部分。
