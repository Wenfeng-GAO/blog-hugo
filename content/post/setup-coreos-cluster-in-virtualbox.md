---
title: "Setup Coreos Cluster Manually with Virtualbox"
date: 2016-05-30T18:21:53+08:00
tags: ["coreos", "docker"]
---

Recently, I wanted to set up a tiny CoreOS cluster in my laptop, the good news is that with several
commands and the existed Vagrantfile offered by the CoreOS official guide, we can setup a cluster
in minutes; the bad news is that I don't like everything perfectly done by [Vagrant](https://www.vagrantup.com/)
like a magic box, I want to do it total manually, and there's no tutorial as I expected.

So as I made it work finally, it's time to share with others.

### Before we start

[CoreOS](https://coreos.com/) is a very cool opensource operating system, which is designed for security, consistency, and reliability.
Instead of installing packages via yum or apt, CoreOS uses Linux containers to manage your services
at a higher level of abstraction. A single service's code and all dependencies are packaged within
a container that can be run on one or many CoreOS machines.

It uses [etcd](https://coreos.com/etcd/) as the key value store service, and uses [fleet](https://coreos.com/etcd/) to manage the containers in the cluster.

And if you just want to setup a cluster locally as fast as posssible, try [Running CoreOS on Vagrant](https://coreos.com/os/docs/latest/booting-on-vagrant.html).

Finally, before we start to setup manually, make sure you have *VirtualBox* installed.

### Part 1, install CoreOS image and setup a User

##### 1. [Download stable ISO](https://coreos.com/os/docs/latest/booting-with-iso.html).

##### 2. Install in VirtualBox.
Choose *type: Linux*, *Version: Linux 2.6/3.x/4.x(64-bit)*, and set *Memory* at least 1024 MB.
Keep clicking *next* until *finish*. Once it's done, click *Storage* tab and add your iso image to the IDE controller, then click *Network*
tab, change connection type from *NAT* to *Bridge*, because we need a static IP address to do the following configurations.
Now we just boot up our VM, and we'll see this if everything goes right.
![ISO Install Complete](http://pn9ta8hbk.bkt.clouddn.com/iso_install_complete.PNG)
This means we have a live version of CoreOS running on VirtualBox, with the default *core* user logged in.

##### 3. Create *cloud-config.yml* file
In the current repository,
Run

		openssl passwd -1 > cloud-config.yml

This is for getting an enscrypted password for logging in. The system prompts you for password and then asks to verify it.
Once done successfully, you get the hash for your password.

The *cloud-config* file uses [YAML](http://yaml.org/). We need follow the [file format](https://coreos.com/os/docs/latest/cloud-config.html#file-format) to make sure CoreOS recognizes and processes the file.
The script is something like this:

```yml
#cloud-config
users:
  - name: wenfeng
    passwd: $1$QJq0Z7rL$GjaetUaSVEU0hM5N3VKpn.
    groups:
      - sudo
      - docker
```

##### 4. Install the CoreOS standalone version
Once `cloud-config.yml` file is created, run

		coreos-cloudinit -validate --from-file cloud-config.yml

to verify you have done it with no syntax and format errors.

Then, run

		sudo coreos-install -d /dev/sda -C stable -c cloud_config.yml

This will download and install the latest stable CoreOS release on your virtual machine.
The success message at the end confirms the CoreOS installation if everything goes well.

Unmount the ISO image from the IDE controller and reboot the virtual machine.
If everything’s right, the virtual machine should reboot and you should be able to login using the username and password set in the cloud-config file.

 Here are another two tutorials of installing CoreOS to VirtualBox.

- [BASIC (NEWBIE) INSTALL COREOS ON VIRTUALBOX – GETTING STARTED WITH DOCKER](http://www.liberidu.com/blog/2015/04/11/basic-newbie-install-coreos-on-virtualbox-getting-started-with-docker/)
- [Get started with CoreOS and VirtualBox](https://deis.com/blog/2015/coreos-on-virtualbox/)

### Part 2, setup cluster
We'll create a cluster of 3 node, so follow the **Part 1** to create 3 CoreOS host.
As we install CoreOS by `coreos-install` command, the system will create a *user_data* file in `/var/lib/coreos-install` directory, and it will reload this file every time it boots up.
So we will update this file in order to setup the cluster.

##### 1. Generate *discovery* key
We use the public discovery service provided by CoreOS to setup the *etcd* cluster, first run this command in your CLI

		curl https://discovery.etcd.io/new?size=3

We'll get an url like `https://discovery.etcd.io/4e70847e1c43b9c10ac52bdf27a4698b`, copy that for later use.

##### 2. Update *user_data* file
Loggin or `ssh` to each CoreOS host VM, run

		sudo vi /var/lib/coreos-install/user_data

Update the file like:

```yml
#cloud-config

coreos:
  etcd2:
    # generate a new token for each unique cluster from https://discovery.etcd.io/new?size=3
    # specify the initial size of your cluster with ?size=X
    discovery: https://discovery.etcd.io/4e70847e1c43b9c10ac52bdf27a4698b
    advertise-client-urls: http://<your-coreos-vm-ip-address>:2379,http://<your-coreos-vm-ip-address>:4001
    initial-advertise-peer-urls: http://<your-coreos-vm-ip-address>:2380
    # listen on both the official ports and the legacy ports
    # legacy ports can be omitted if your application doesn't depend on them
    listen-client-urls: http://0.0.0.0:2379,http://0.0.0.0:4001
    listen-peer-urls: http://<your-coreos-vm-ip-address>:2380
  units:
    - name: etcd2.service
      command: start

    - name: fleet.service
      command: start


users:
  - name: wenfeng
    passwd: $1$QJq0Z7rL$GjaetUaSVEU0hM5N3VKpn.
    groups:
      - sudo
      - docker
```

##### 3. Check cluster status
Once you have updated the *user_data* file of each CoreOS VM, reboot them at the same time and you will get
a cluster automatically.

If everything goes well, `ssh` to a host and run

		systemctl status etcd2

You should see some thing like:
![etcd2 status](http://pn9ta8hbk.bkt.clouddn.com/etcd2_status.PNG)

Run

		fleetctl list-machines

You should see come thing like:
![cluster machine status](http://pn9ta8hbk.bkt.clouddn.com/cluster_machine_status.PNG)

Now every goes perfectly, deploy your services and enjoy CoreOS cluster!

### Trouble shooting
1. You can use `journalctl -f -t etcd2` to see logs of *etcd2* if any error occurs.
2. All CoreOS VMs in the cluster share the same *discovery key*, and you should generate a new one every time you
setup a new cluster
3. Try `sudo rm -rf  /run/systemd/system/etcd2.service.d/` and `sudo rm -rf /var/lib/etcd2`, regenerate *discovery key* and reboot the VM if needed.
4. Your CoreOS VMs should be able to connect the Internet.

