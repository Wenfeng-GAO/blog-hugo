---
title: "Deploy Worldpress in Coreos Cluster Using Fleet"
date: 2016-06-03T18:22:13+08:00
tags: ["coreos", "docker"]
---

In this post, I would like to tell you how to deploy a simple WorldPress service
with MySQL database in [CoreOS cluster](https://coreos.com/) in 3 minutes.
You may reference [my previous blog](http://wenfeng-gao.github.io/2016/05/30/setup-coreos-cluster-in-virtualbox.html)
 to setup a CoreOS cluster locally if you don't have one.

Ok, `ssh` to one of your cluster node, let's start.

### Step 1 Create MySQL service
 Create a unit file `mysql.service`

```yml
 [Unit]
Description=MySQL DataBase
After=etcd.service
After=docker.service

[Service]
TimeoutStartSec=0
ExecStartPre=-/usr/bin/docker kill mysql
ExecStartPre=-/usr/bin/docker rm mysql
ExecStartPre=/usr/bin/docker pull mysql:5.7
ExecStart=/usr/bin/docker run --name mysql -e MYSQL_ROOT_PASSWORD="wordpress" -e MYSQL_DATABASE="wordpress" -e MYSQL_USER="wordpress" -e MYSQL_PASSWORD="wordpress" mysql:5.7
ExecStop=/usr/bin/docker stop mysql
```

To start service, run

    fleetctl start mysql.service

To view its status, (normally it should be *active* and *running*) run

    fleetctl list-units


### Step 2 Create WordPress service
Create the second unit file `wordpress.service`

```yml
[Unit]
Description=WordPress
After=mysql.service

[Service]
TimeoutStartSec=0
ExecStartPre=-/usr/bin/docker kill wordpress
ExecStartPre=-/usr/bin/docker rm wordpress
ExecStartPre=/usr/bin/docker pull wordpress
ExecStart=/usr/bin/docker run --name wordpress --link mysql -p 8880:80 -e WORDPRESS_DB_PASSWORD=wordpress -e WORDPRESS_DB_NAME=wordpress -e WORDPRESS_DB_USER=wordpress wordpress
ExecStop=/usr/bin/docker stop wordpress

[X-Fleet]
X-ConditionMachineOf=mysql.service
```

Run

    fleetctl start wordpress.service

Ok, it's done! Go *http://\<your-coreos-host-ip>:8880* and you should see the
WordPress install page.

![WordPress Install Page](http://pn9ta8hbk.bkt.clouddn.com/wordpress.PNG)

### A bit Explanation
- `TimeoutStartSec=0` aims to turning off timeouts, as the `docker pull` may take
a while
- `X-ConditionMachineOf=mysql.service` means *wordpress* service runs on the
same host with *mysql* service

