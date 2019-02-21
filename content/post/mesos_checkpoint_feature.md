---
title: "Mesos Checkpoint Feature & Master Agent Connection"
date: 2017-05-18T09:56:49+08:00
tags: ["docker", "mesos"] 
draft: true
gitment: true
---

Mesos在更新版本后将slave改名为agent，所以本文中的agent与mesos-slave完全等同。

本文将讨论的问题：

- Mesos checkpoint 机制的作用
- Mesos master 与 agent连接检查的机制
- Mesos master 与 agent连接断开后的状态变化


## Usage of Mesos Checkpoint Feature

Mesos的`checkpoint`功能主要能起到3个作用：

###### Agent disconnect with executor

- 当agent线程挂掉，或者与executor无法连接时，如果framework没有使用`checkpoint`，executor一旦发现与agent断开，立即自动退出。
- 如果framework使用了`checkpoint`，executor将在一段时间内（`MESOS_RECOVERY_TIMEOUT`）尝试重连，超出timeout之后才会自动退出。这个时间的设置可以通过`--recovery_timeout`标签来设置，默认15分钟。

###### Agent disconnect with master

- 当agent线程挂掉，或者与master连接断开时，如果没有`checkpoint`，master会立即为此agent管理的所有task发送`TASK_LOST`状态变更的信息，然后等待一段时间，给agent重连的机会（这段时间为mesos `health check`的时间，可以通过`--agent_ping_timeout` 和 `--max_agent_ping_timeouts`标签来设置），如果agent重连成功，master会kill掉之前发送`TASK_LOST`的所有task。
- 如果使用了`checkpoint`，master不会发送`TASK_LOST`，而是直接等待，如果重连成功了，也不会kill任何task，就像什么也没有发生一样。

###### Agent recovery

- 当agent重启后，如果没有`checkpoint`，agent管理的还存活着的task会被立即重启。
- 如果使用了`checkpoint`，agent会将一些信息（`Task Info`, `Executor Info`, etc.）写入本地磁盘，重启后可以根据设置来进行恢复。
	这些设置有3个：
    - `strict`: 若为true，恢复时出现的所有`error`将被视为`fatal`，恢复中断；若为`false`，忽略所有`error`，以最大的可能去恢复；默认为`true`。
    - `recover`：若为`reconnect`，重连所有存活的`executor`；若为`cleanup`，kill所有存活的`executor`并退出；默认为`reconnect`。
    - `recovery_timeout`，前面也有所提到，这是给agent预留的恢复时间，如果超过这个时间后还有`executor`没有连到，那么那些`executor`将会自动退出，默认时间为15分钟。

## Dealing with Partitioned or Failed Agents

#### 2 mechanisms to track availability and health

Mesos master用两种方法来检测跟踪agent的可靠性：

- Master 与 agent之间`tcp`连接的状态
- `Health check`：通过master间断性地给agent发`ping`来检测，如果agent连续几次都响应失败，就判定为失联。`health check`的时间可以通过这两个标签来控制：
	- `--agent_ping_timeout（--slave_ping_timeout）`：agent响应`ping`的时间限制，超出时间还未响应则为失败，默认为15秒。
	- `--max_agent_ping_timeouts (--max_slave_ping_timeouts)`：master可容忍的响应失败次数，默认为5。

所以默认的`health check` timeout为`15*5=75`秒。重启的agent需要在这个时间之内`re-register` master，不然master将`shutdown` 这个agent，而收到`shutdown`信号的agent会kill它管理的所有`executor`和`task`并退出。

值的注意的是，这个时间设置需要大于`ZooKeeper session timeout`以避免无用的`re-register`尝试。

#### Steps to remove disconnected agent

当master检测到agent失联后，会采取步骤从列表中删掉失联的agent，这其中的步骤也会分有`checkpoint`和没有`checkpoint`，这在前面也有所提及。

可以看以下图示：

![](/assets/mesos-checkpoint-master-agent-connection/mesos-master-agent.jpg)

若没有开启`checkpoint`，master会立即发送`TASK_LOST` message，只有如果重连成功，会kill掉这些task。

如果在`health check timeout`时间内重连失败，master会从注册agent列表里移除这个agent，并且发送`SLAVE_LOST`的callback和相应的`TASK_LOST`的信息。

而值得注意的是，不管`SLAVE_LOST callback`还是`TASK_LOST status update message`，mesos都不保证发送的信息是可靠的，即使因为网络原因中途丢失了，也只会发一次。

被移除列表的agent依然会持续尝试重连master，它所管理的`executor`和`task`也会继续运行，如果重连成功了的话（比如网络问题修复了），master会要求agent `shutdown`，agent会`shutdown`所有task并退出。官方建议使用process supervisor（e.g. systemd）来自动启动mesos-slave。

这个过程中有几个配置项值得考虑：

- `--agent_removal_rate_limit(--slave_removal_rate_limit)`: 当agents `health check`失败后，从master注册列表中被移除的速度（如`1/10mins`，`2/3hrs`等），默认为立即移除。
- `--recovery_agent_removal_limit(--recovery_slave_removal_limit)`: 限制agent被master从注册列表中移除的和`shutdown`的比例，如果超过这个比例，master将不会移除agent，而是自身`failover`，通过这个设置可能增加生产环境的安全性，默认为`100%`。
- `agent_reregister_timeout(--slave_reregister_timeout)`: agent重连master的时间限制。agent与master断开连接或有新的master被选为leader时，会尝试`re-register`，默认设置时间10分钟，设置必须大于或等于10分钟。

## Dealing with Partitioned or Failed Masters

由于大部分的master state只存在内存中，当master `failover`，新的master被选出时，新master对集群的状态将一无所知，直到有agent `re-register`这个新的master。在这期间如果去询问某台agent的task状态，将没有任何回应。

如果agent没有在`--agent_reregister_timeout`时间内重连新的master，master将标记这个agent为失败并执行前面提到过的步骤。唯一不同的是，agent被允许连接新的master即使已经超过了timeout。这表示framework可能会看到`TASK_LOST`状态更新，之后却发现task正在运行(因为agent被允许连入)。

