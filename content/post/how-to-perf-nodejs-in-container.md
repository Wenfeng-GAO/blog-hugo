---
title: "How to Perf Nodejs Apps in Container"
date: 2019-10-24T09:50:45+08:00
lastmod: 2019-10-24T09:50:45+08:00
keywords: ["perf", "flamegraph", "nodejs"]
tags: ["perf", "flamegraph", "nodejs"]
categories: ["performance"]
summary: "In my previous blogs, I've shared about how to profile Java applications in
various of methods, now I'll show you how to profile Nodejs apps with perf..."
---

In my previous blogs, I've shared about how to profile Java applications in
various of methods, now I'll show you how to profile Nodejs apps with
[perf](http://www.brendangregg.com/perf.html).

Let's get started.

## Run App with `--perf-basic-prof` Argument
First of all, as Nodejs application has a V8 virtual machine and [JIT](https://en.wikipedia.org/wiki/Just-in-time_compilation) process,
*perf* can't get the stack traces directly, so we need a solution to achieve
this.

### Linux perf_events JIT support

In 2009, Linux perf_events added JIT symbol support, so that symbols from
language virtual machines like the JVM/V8 could be inspected.  It works in the
following amazingly simple way:

1. Your JIT application must be modified to create a `/tmp/perf-PID.map` file,
which is a simple text database containing symbol addresses (in hex), sizes,
and symbol names.
2. That's it.

perf already looks for the `/tmp/perf-PID.map` file, and if it finds it, it uses
it for symbol translations. So only v8 needed to be modified.

### v8 --perf-basic-prof support

In November 2013, v8 added perf_events support, enabled using the `--perf-basic-prof` option. This made it into node v0.11.13. It works like this:
```bash
# ~/node-v0.11.13-linux-x64/bin/node --perf-basic-prof hello.js &
[1] 31441
# ls -l /tmp/perf-31441.map
-rw-r--r-- 1 root root 81920 Sep 17 20:41 /tmp/perf-31441.map
# tail /tmp/perf-31441.map
14cec4db98a0 f Stub:BinaryOpICWithAllocationSiteStub(ADD_CreateAllocationMementos:String*Generic->String)
14cec4db9920 f Stub:BinaryOpICWithAllocationSiteStub(ADD_CreateAllocationMementos:String*String->String)
14cec4db99a0 f Stub:BinaryOpICWithAllocationSiteStub(ADD_CreateAllocationMementos:String*Smi->String)
14cec4db9a20 22c LazyCompile:~nextTick node.js:389
14cec4db9cc0 156 Stub:KeyedLoadElementStub
14cec4db9e80 22 KeyedLoadIC:
14cec4db9f20 22 KeyedLoadIC:
14cec4db9fc0 56 Stub:DoubleToIStub
14cec4dba080 10c Stub:KeyedStoreElementStub
```
This text file is what perf_events reads.

As I run Nodejs applications with [pm2](http://pm2.keymetrics.io/) in Docker
container, I'll `--perf-basic-prof` argument like this:
```bash
pm2 start index.js \
          --node-args --perf-basic-prof
```

## Perf outside of container
I decide to perf out side of container mainly because of the following 2
reasons:

- additional previlege permissions should be added to container in order to
  support perf_event_open syscall
- perf inside container may increase a bit of overhead to application
namespace

Because we perf outside of container, we need get application's host PID to
perf.
```bash
$ docker top a3115
UID     PID      PPID     STIME    TIME       CMD
1004    65462    14902    10:43    00:00:01   PM2 v2.9.1: God Daemon (/home/deploy/.pm2)
1004    65700    65462    10:43    00:00:01   node /opt/app/node/lib/node_modules/pm2/lib/HttpInterface.js
1004    65875    65462    10:43    00:00:03   node /opt/nodeapp/index.js
```
Here `65875` is our target PID to perf.
```bash
perf record -F 99 -p 65875 -g -- sleep 30
```

## Prepare `/tmp/perf-65875.map` file
As we perf outside of container, `/tmp/perf-PID.map` file was generated inside
container, we have to copy it out before next process.
```bash
# find file in container
$ docker exec a3115 sh -c "ls -l /tmp/perf*.map"
-rw-rw-r-- 1 deploy deploy 686639 Oct 24 11:51 /tmp/perf-384.map

# copy out, don't forget to change file name with host pid
$ docker cp a3115:/tmp/perf-384.map /tmp/perf-65875.map
```

## Generate Flame Graph
```bash
perf script -f > out.nodestacks01
```
We need Gregg's [FlameGraph](http://github.com/brendangregg/FlameGraph) to generate flame graph.
```bash
git clone --depth 1 http://github.com/brendangregg/FlameGraph
```
Generate
```bash
cd FlameGraph
./stackcollapse-perf.pl < ../out.nodestacks01 | ./flamegraph.pl --color=js > ../out.nodestacks01.svg
```
Now we can get a flame graph like this:

![nodejs perf
flamegraph](/post/how-to-profile-nodejs-in-container/nodejs_perf_flamegraph.svg)

## Overall script
You can download `FlameGraph` then use this script to get the svg file outside
the container.
```bash
#!/bin/bash

set -e
set -x

CTN_ID="$1"
PROFILING_DURATION="$2"
PIDs=`docker top $CTN_ID | grep /opt/nodeapp | awk '{print $2}'`
CTN_PIDs=`docker exec $CTN_ID ps aux | grep /opt/nodeapp | awk '{print $2}'`


# check /tmp/perf-PID.map files exist
for ctn_pid in $CTN_PIDs
do
  if ! docker exec $CTN_ID stat /tmp/perf-$ctn_pid.map; then
    exit 111
  fi
done

# copy /tmp/perf-PID.map files out of container
for host_pid in $PIDs
do
  ctn_pid=`awk '/NSpid/ {print $NF}' /proc/$host_pid/status`
  docker cp $CTN_ID:/tmp/perf-$ctn_pid.map /tmp/perf-$host_pid.map
done

# perf
HOST_PIDs=`echo $PIDs|tr ' ' ','`
perf record -F 99 -p $HOST_PIDs -g -- sleep $PROFILING_DURATION
perf script -f | FlameGraph/stackcollapse-perf.pl | FlameGraph/flamegraph.pl --color=js > $CTN_ID.$(date +%s).svg
```

## References
- [gregg's blog about nodejs perf](http://www.brendangregg.com/blog/2014-09-17/node-flame-graphs-on-linux.html)
- [gregg's flame graphs blog](http://www.brendangregg.com/FlameGraphs/cpuflamegraphs.html)
- [similar good blog](https://shuheikagawa.com/blog/2018/09/16/node-js-under-a-microscope/)
- [nodejs perf with flamescope](https://medium.com/yld-blog/cpu-and-i-o-performance-diagnostics-in-node-js-c85ea71738eb)
