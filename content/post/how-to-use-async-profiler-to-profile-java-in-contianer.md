---
title: "How to Use async-profiler to Profile Non-root Java Process in Contianer"
date: 2019-10-14T15:53:55+08:00
lastmod: 2019-10-14T15:53:55+08:00
keywords: ["async-profiler", "docker", "perf", "flamegraph"]
tags: ["async-profiler", "perf", "flamegraph", "docker"]
categories: ["performance", "trouble shooting"]
summary: "In this article, I will share you how to profile non-root java process in
container with async-profiler. Async-profiler is one of the popular ways to
profile java process, I'll present the process and the difficulties I met while
using this tool."
---

# Ways for Java CPU Profiling
In order to profile Java processes and get cpu usage hot points(better shown
with flame graph), there're 3 popular ways:

1. perf + perf-map-agent + FlameGraph

    Linux perf tool and Gregg's [FlameGraph](https://github.com/brendangregg/FlameGraph)
    can do the job well, but as Java has a
    JVM virtual machine and JIT in-line feature, perf can't get Java's stack trace
    directly, here [perf-map-agent](https://github.com/jvm-profiling-tools/perf-map-agent)
    comes to help.

    *perf-map-agent* aims to provide a map file for symbols of in-line code.
    `XX:+PreserveFramePointer` should be added when launce jvm as well.

    There're already many good tutorials and blogs about this method, so we won't go
    deeper here.

2. eBPF + perf-map-agent + FlameGraph

    Use eBPF instead of perf tool can alse work well, and it cost lower overhead
    theoretically. I've written another blog to share the detail about this
    ([How To Profile Java Program With eBPF/bcc Tool](https://wenfeng-gao.github.io/post/profile-java-program-with-bcc-tool/)).

3. async-profiler

    [jvm-profiling-tools/async-profiler](https://github.com/jvm-profiling-tools/async-profiler) is
    an open-source low overhead sampling profiler for Java.

    For CPU profiling, it uses perf with `AsyncGetCallTrace`, for visualization it
    has flame graph support out of box.

async-profiler already support [profiling Java in a container](https://github.com/jvm-profiling-tools/async-profiler#profiling-java-in-a-container),
but I still met some obstacles while trying to use it.

# Getting started
It's possible to profile both within the Docker container or from the host
system, I tried both and both works well. Here I introduce profile within the
container.

## Easy to Use
Just download the async-profiler in place, it's quite easy to use:
```bash
./profiler.sh start PID
./profiler.sh stop PID

# flame graph output
./profiler.sh -d DURATION -f /path/to/output.svg PID
```
For CPU profiling, you may get some flame graphs like this.
![flame graph](/post/how-to-use-async-profiler-to-profile-java-in-container/flame_graph.svg)

## Troubleshooting
When I use async-profiler the first time inside the contianer, I got some
permission errors.
```bash
$ ./profiler.sh start PID

Perf events unavailable. See stderr of the target process.
```
And in my error logs, I found this:
```bash
perf_event_open failed: Permission denied
Try with --all-user option, or 'echo 1 > /proc/sys/kernel/perf_event_paranoid'
perf_event_open failed: Permission denied
perf_event_open failed: Permission denied
...
```

What is `perf_event_paranoid`? It's a `sysctl` file used to control the
permission of unprivileged user to use perf_event.

```bash
perf_event_paranoid:

Controls use of the performance events system by unprivileged
users (without CAP_SYS_ADMIN).  The default value is 2.

 -1: Allow use of (almost) all events by all users
     Ignore mlock limit after perf_event_mlock_kb without CAP_IPC_LOCK
>=0: Disallow ftrace function tracepoint by users without CAP_SYS_ADMIN
     Disallow raw tracepoint access by users without CAP_SYS_ADMIN
>=1: Disallow CPU event access by users without CAP_SYS_ADMIN
>=2: Disallow kernel profiling by users without CAP_SYS_ADMIN
```

And you can't modify the file directly in the container, because it's read-only:
```bash
$ echo 0 > /proc/sys/kernel/perf_event_paranoid
bash: /proc/sys/kernel/perf_event_paranoid: Read-only file system
```

You have to do this command on the host system, in which case will definitly
affect all containers on this host, which leverages some kind of security risks.

In addition, you may need to modify [seccomp profile](https://docs.docker.com/engine/security/seccomp/) 
or disable it altogether with `--security-opt=seccomp:unconfined` option.
As my containers are running in Kubernetes cluster, which disables `seccomp` by
default, I no longer need to do this.

### For privileged user
As my Java process runs as unprivileged, I have to deal with the
`perf_event_paranoid` issue, however, if you run Java process as root user or
init process, you only need to add `SYS_ADMIN` capabilities to your container.
([This blog](https://blog.alicegoldfuss.com/enabling-perf-in-kubernetes/) may
help in this case.)

# References
- [sysctl doc](https://www.kernel.org/doc/Documentation/sysctl/kernel.txt)
- [stackoverflow perf_event_paranoid](https://stackoverflow.com/questions/51911368/what-restriction-is-perf-event-paranoid-1-actually-putting-on-x86-perf)
- [Profiling Java Applications with Async
  Profiler](https://hackernoon.com/profiling-java-applications-with-async-profiler-049s2790)
- [Profiling the JVM on Linux: A Hybrid Approach](http://blogs.microsoft.co.il/sasha/2017/07/07/profiling-the-jvm-on-linux-a-hybrid-approach/)
