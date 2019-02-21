---
title: "Core Dump File Size Limit in Docker"
date: 2018-05-15T18:24:30+08:00
tags: ["docker"]
---

### Background
工作中遇到这样一个问题，运行环境为Docker容器，由于设置了容器的磁盘大小，但是没有设置core dump file的大小（默认为unlimited），当程序收到`SIGABRT`信号退出时，磁盘容易被撑满。

所以决定不让其产生core dump file。那么问题来了，在Docker容器环境下，该如何实现？

以下记录了围绕这个目的所做的一些尝试与遇到的问题。

### Try and try

#### Method 1: 使用`systemd` [failed]
Systemd's default behavior is to generate core dumps for all processes in `/var/lib/systemd/coredump`. This behavior can be overridden by creating a configuration snippet in the `/etc/systemd/coredump.conf.d/` directory with the following content.

```bash
/etc/systemd/coredump.conf.d/custom.conf
[Coredump]
Storage=none
```

然后重载`systemd`的配置

	systemctl daemon-reload

但是，结果是我们会得到一个诸如`Failed to get D-Bus connection: Operation not permitted`的error。根据14年的issue [Failed to get D-Bus connection: No connection to service manager - CentOS 7 #7459](https://github.com/moby/moby/issues/7459)，我们并不能在容器中直接使用systemctl，而是需要用我们自己的process manager（supervisor）来管理进程。

这将带来额外更多的工作量，决定放弃这种方法。

#### Method 2： 使用ulimit，更改`/etc/security/limits.conf`配置 [failed]

	* hard core 0

一般来说，在`limits.conf`文件中添加如上更改，便不会产生core file。然而我们restart容器之后，发现文件虽然确实被修改过，但是通过`ulimit -c`发现并没有作用。

根据 [Stackoverflow Ref](http://stackoverflow.com/questions/24180048/linux-limits-conf-not-working),  `limits.conf`文件是被`pam_limits.set`读取的, 我们修改`/etc/pam.d/su`，使得

	session         required        pam_xauth.so

然而依然没有任何作用，或许我们还可以尝试通过`--priviliged`，挂载文件系统等等方法来尝试，但这样依然代价太大，我们放弃。

#### Method 3：`docker run --ulimit core=0:0` [succeed]
通过起容器时添加`--ulimit`标签无疑是最方便的做法，而最重要的是，它成功了！

当我们进入容器执行`ulimit -c`，返回`0`。恭喜我们，目标达成！

### Verify and experiment
现在我们想人为造一点core dump出来，来验证这个方法确实起作用了，该怎么办呢？

#### Method 1：`gdb` and `generate-core-file` [failed]
或许我们可以用`gdb`的`generate-core-file`工具。

首先我们执行一个简单的线程

```python
test.py
#!/usr/bin/env python

import time

while True:
        print 'hi'
        time.sleep(2)
```

然后通过`ps -ef`找到这个进程的`PID`，执行`gdb -p PID`，然而这时，问题又来了:

```bash
Attaching to process 145
ptrace: Operation not permitted.
(gdb) generate-core-file
You can't do that without a process to debug.
```

而通过这个开了又关关了又开的长长的GitHub Issue [apparmor denies ptrace to docker-default profile #7276](https://github.com/moby/moby/issues/7276)，我大概知道，还是找个别的方法更省力。

#### Method 2: `kill -ABRT PID` [succeed]
通过`man`文档，我们知道这几个`signal`可以产生core dump文件：

```bash
   SIGQUIT       3       Core    Quit from keyboard
   SIGILL        4       Core    Illegal Instruction
   SIGABRT       6       Core    Abort signal from abort(3)
   SIGFPE        8       Core    Floating-point exception
```


这时我们发现，当`ulimit -c`设为`0`时，确实不会产生core dump文件；

而当我们把`ulimit -c`设为`4`时，产生了core dump，使用`gdb ./test.py core.PID` debug时，却发现了这样的warning。

	BFD: Warning: /root/core.129 is truncated: expected core file size >= 2945024, found: 5488.


我们`docker run -it --ulimit core=2945024 ...`增加`ulimit -c`的大小，这次得到大小为`2.9M`的core dump file，使用`gdb`也再没有问题。

看来，一个完整的core file至少为`2945024 byte`，当我们设置的`ulimit -c`的值小于它时，可能得到不完整的文件，如果设置的更小，比如小于`3 * 1024`，便不会产生文件，设置为`0`，便是禁止了。

### Conclusion
这便是我解决这个问题的一个过程吧，其中踩过了一些坑，也学到了很多新东西，希望能对你也有帮助。 以下是一些解决问题过程中参考过的，觉得有价值的链接，enjoy！

- [man ulimit](https://ss64.com/bash/ulimit.html)
- [man core - core dump file](http://man7.org/linux/man-pages/man5/core.5.html)
- [docker run with ulimit](https://docs.docker.com/engine/reference/commandline/run/#set-ulimits-in-container---ulimit)
- [quick use of gdb](http://stackoverflow.com/questions/8305866/how-to-analyze-a-programs-core-dump-file-with-gdb)

