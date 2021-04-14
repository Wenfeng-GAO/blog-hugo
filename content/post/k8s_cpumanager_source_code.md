---
title: "Kubernetes源码分析之CPU Manager"
date: 2018-11-28T23:14:35+08:00
keywords: ["kubernetes", "kubelet", "cpumanager", "sourcecode"]
tags: ["kubernetes", "kubelet"]
categories: ["k8s"]
---

# 背景

Kubelet默认使用CFS Quota/Share的方式来实现Pod的CPU层面约束，而对于[cpuset](https://www.kernel.org/doc/Documentation/cgroup-v1/cpusets.txt)的支持，通过很长一段时间的讨论（[[Issue] Determine if we should support cpuset-cpus and cpuset-mem](https://github.com/kubernetes/kubernetes/issues/10570))后，最终通过[CPU Manager](https://kubernetes.io/docs/tasks/administer-cluster/cpu-management-policies/)来实现。

CPU Manager作为alpha版本从v1.8开始出现，自v1.10开始作为beta版本默认开启。

# 使用方式

v1.10版本前需要开启`feature-gate`。
```bash
 --feature-gates=CPUManager=true
 ```
开启cpuset还需要一些cpumanager的参数设置
```bash
--cpu-manager-policy=static
--cpu-manager-reconcile-period=10s / Optional, default same as `--node-status-update-frequency`
```

还需要设置cpu reservation，可以通过
```bash
--kube-reserved
// or
--system-reserved
```

# 源码分析
## Start CPU Manager
在kubelet启动之时，cpuManager会被生成，并`Start`。此时，cpuManager已经获取了所在宿主机的cpu拓扑结构，并且另起goroutine每隔`reconcilePeriod`时间，对宿主机上所有的`activePods`做一次`reconcile`。

`kubelet.go`
```go
// initializeModules will initialize internal modules that do not require the container runtime to be up.
// Note that the modules here must not depend on modules that are not initialized here.
func (kl *Kubelet) initializeModules() error {
	...
	if err := kl.containerManager.Start(node, kl.GetActivePods, kl.sourcesReady, kl.statusManager, kl.runtimeService); err != nil {
		return fmt.Errorf("Failed to start ContainerManager %v", err)
	}
	...
	return nil
}
```

`container_manager_linux.go`

```go
func (cm *containerManagerImpl) Start(node *v1.Node,
	activePods ActivePodsFunc,
	sourcesReady config.SourcesReady,
	podStatusProvider status.PodStatusProvider,
	runtimeService internalapi.RuntimeService) error {

	// Initialize CPU manager
	if utilfeature.DefaultFeatureGate.Enabled(kubefeatures.CPUManager) {
		cm.cpuManager.Start(cpumanager.ActivePodsFunc(activePods), podStatusProvider, runtimeService)
	}

	...
	return nil
}
```

`cpu_manager.go`
```go
func (m *manager) Start(activePods ActivePodsFunc, podStatusProvider status.PodStatusProvider, containerRuntime runtimeService) {
	glog.Infof("[cpumanger] starting with %s policy", m.policy.Name())
	glog.Infof("[cpumanger] reconciling every %v", m.reconcilePeriod)

	m.activePods = activePods
	m.podStatusProvider = podStatusProvider
	m.containerRuntime = containerRuntime

	m.policy.Start(m.state)
	if m.policy.Name() == string(PolicyNone) {
		return
	}
	go wait.Until(func() { m.reconcileState() }, m.reconcilePeriod, wait.NeverStop)
}
```
可以看见，在kubelet启动之时会调用`kl.containerManager.Start`来启动`containerManager`，而`containerManager`一上来会先判断`cpuManager Feature Gate`是否开启了，如果是，则调用`cm.cpuManager.Start`。

在`cpuManager.Start()`方法中，实际上只做了一件事情——如果`policy`为`static`，则每隔`reconcilePeriod`时间，执行一次`reconcileState()`方法。

看到这里，也大概明白了参数设置`--cpu-manager-policy=static`，`--cpu-manager-reconcile-period`的用意了。

## Reconcile
### Reconcile方法做了什么事情？
`Reconcile`循环处理宿主机上的`activePods`，主要做了3件事：
1. 找到`containerID`
2. 获取这个container需要绑定的cpuset
3. 更新这个container

### 为什么要做
实际上，在cpuManager创建之时，便得到了host的cpu拓扑，这时cpuManager维护一个cpu资源池，每当有新的pod需要使用cpuset，便从这个资源池中调走一些cpu来给其使用，使用cpuset的pod绑定并独占这些cpu核，而原本可以使用整个资源池资源的其他非cpuset的pod，现在都需要更新一把，使其使用最新的（缩小了的）cpu资源池。

这就是`go wait.Until(func() { m.reconcileState() }, m.reconcilePeriod, wait.NeverStop)`的用意所在。

>所以理论上来说，刚刚使用cpuset的pod最长要等到`reconcilePeriod`之后，才能完全独占其CPU。

`cpu_manager.go`
```go
func (m *manager) reconcileState() (success []reconciledContainer, failure []reconciledContainer) {
	success = []reconciledContainer{}
	failure = []reconciledContainer{}

	for _, pod := range m.activePods() {
		allContainers := pod.Spec.InitContainers
		allContainers = append(allContainers, pod.Spec.Containers...)
		for _, container := range allContainers {
			status, ok := m.podStatusProvider.GetPodStatus(pod.UID)
			if !ok {
				glog.Warningf("[cpumanager] reconcileState: skipping pod; status not found (pod: %s, container: %s)", pod.Name, container.Name)
				failure = append(failure, reconciledContainer{pod.Name, container.Name, ""})
				break
			}

			containerID, err := findContainerIDByName(&status, container.Name)
			if err != nil {
				glog.Warningf("[cpumanager] reconcileState: skipping container; ID not found in status (pod: %s, container: %s, error: %v)", pod.Name, container.Name, err)
				failure = append(failure, reconciledContainer{pod.Name, container.Name, ""})
				continue
			}

			cset := m.state.GetCPUSetOrDefault(containerID)
			if cset.IsEmpty() {
				// NOTE: This should not happen outside of tests.
				glog.Infof("[cpumanager] reconcileState: skipping container; assigned cpuset is empty (pod: %s, container: %s)", pod.Name, container.Name)
				failure = append(failure, reconciledContainer{pod.Name, container.Name, containerID})
				continue
			}

			glog.V(4).Infof("[cpumanager] reconcileState: updating container (pod: %s, container: %s, container id: %s, cpuset: \"%v\")", pod.Name, container.Name, containerID, cset)
			err = m.updateContainerCPUSet(containerID, cset)
			if err != nil {
				glog.Errorf("[cpumanager] reconcileState: failed to update container (pod: %s, container: %s, container id: %s, cpuset: \"%v\", error: %v)", pod.Name, container.Name, containerID, cset, err)
				failure = append(failure, reconciledContainer{pod.Name, container.Name, containerID})
				continue
			}
			success = append(success, reconciledContainer{pod.Name, container.Name, containerID})
		}
	}
	return success, failure
}
```
从以上代码，我们知道通过调用`cset := m.state.GetCPUSetOrDefault(containerID)`，来获取container需要绑定的cpuset。那么它具体是如何获取的呢？
```go
// NewManager creates new cpu manager based on provided policy
func NewManager(
	cpuPolicyName string,
	reconcilePeriod time.Duration,
	machineInfo *cadvisorapi.MachineInfo,
	nodeAllocatableReservation v1.ResourceList,
	stateFileDirecory string,
) (Manager, error) {
...
	stateImpl := state.NewFileState(
		path.Join(stateFileDirecory, CPUManagerStateFileName),
		policy.Name())

	manager := &manager{
		policy:                     policy,
		reconcilePeriod:            reconcilePeriod,
		state:                      stateImpl,
		machineInfo:                machineInfo,
		nodeAllocatableReservation: nodeAllocatableReservation,
	}
	return manager, nil
}
```
`state_file.go`
```go
// NewFileState creates new State for keeping track of cpu/pod assignment with file backend
func NewFileState(filePath string, policyName string) State {
	stateFile := &stateFile{
		stateFilePath: filePath,
		cache:         NewMemoryState(),
		policyName:    policyName,
	}

	if err := stateFile.tryRestoreState(); err != nil {
		// could not restore state, init new state file
		glog.Infof("[cpumanager] state file: initializing empty state file - reason: \"%s\"", err)
		stateFile.cache.ClearState()
		stateFile.storeState()
	}

	return stateFile
}
```
从以上代码，我们知道cpuManager实际上将`state`(也就是cpu资源池情况)写进了文件与内存cache中。`m.state.GetCPUSetOrDefault(containerID)`实际上是从内存中查找对应`containerID`的cpuset情况。
`state_file.go`
```go
func (sf *stateFile) GetCPUSetOrDefault(containerID string) cpuset.CPUSet {
	sf.RLock()
	defer sf.RUnlock()

	return sf.cache.GetCPUSetOrDefault(containerID)
}
```
`state_mem.go`
```go
type stateMemory struct {
	sync.RWMutex
	assignments   ContainerCPUAssignments
	defaultCPUSet cpuset.CPUSet
}

// NewMemoryState creates new State for keeping track of cpu/pod assignment
func NewMemoryState() State {
	glog.Infof("[cpumanager] initializing new in-memory state store")
	return &stateMemory{
		assignments:   ContainerCPUAssignments{},
		defaultCPUSet: cpuset.NewCPUSet(),
	}
}

func (s *stateMemory) GetCPUSet(containerID string) (cpuset.CPUSet, bool) {
	s.RLock()
	defer s.RUnlock()

	res, ok := s.assignments[containerID]
	return res.Clone(), ok
}

func (s *stateMemory) GetCPUSetOrDefault(containerID string) cpuset.CPUSet {
	if res, ok := s.GetCPUSet(containerID); ok {
		return res
	}
	return s.GetDefaultCPUSet()
}
```
最终cpuset是从`s.assignments[containerID]`中获取的，而`s.assignments`实际上只是一个映射了`containerID`与cpuset的map。
`state.go`
```go
// ContainerCPUAssignments type used in cpu manger state
type ContainerCPUAssignments map[string]cpuset.CPUSet
```
那么问题来了，这个`ContainerCPUAssignments`是何时添加，何时删除的呢？

## AddContainer/RemoveContainer
在`cpu_manager.go`中，我们还看到两个方法：`AddContainer`和`RemoveContainer`，它们的作用之一便是变更`ContainerCPUAssignments`。我们接下来看看它们是如何被使用的。

### AddContainer
kubelet给container添加cpuset信息的地方比较隐蔽。在`kuberuntime.startContainer`中创建container之后，start container之前的`PreStartContainer`中。

`kuberuntime_container.go`
```go
func (m *kubeGenericRuntimeManager) startContainer(podSandboxID string, podSandboxConfig *runtimeapi.PodSandboxConfig, container *v1.Container, pod *v1.Pod, podStatus *kubecontainer.PodStatus, pullSecrets []v1.Secret, podIP string) (string, error) {
	// Step 1: pull the image.
...
	// Step 2: create the container.
...
	err = m.internalLifecycle.PreStartContainer(pod, container, containerID)
	if err != nil {
		m.recorder.Eventf(ref, v1.EventTypeWarning, events.FailedToStartContainer, "Internal PreStartContainer hook failed: %v", err)
		return "Internal PreStartContainer hook failed", err
	}
...
	// Step 3: start the container.
...
	// Step 4: execute the post start hook.
...
	return "", nil
}
```
`internal_container_lifecycle.go`
```go
func (i *internalContainerLifecycleImpl) PreStartContainer(pod *v1.Pod, container *v1.Container, containerID string) error {
	if utilfeature.DefaultFeatureGate.Enabled(kubefeatures.CPUManager) {
		return i.cpuManager.AddContainer(pod, container, containerID)
	}
	return nil
}
```
最终，我们还是回到了cpuManager，看到了`cpuManager.AddContainer`。

`cpu_manager.go`
```go
func (m *manager) AddContainer(p *v1.Pod, c *v1.Container, containerID string) error {
	m.Lock()
	err := m.policy.AddContainer(m.state, p, c, containerID)
	if err != nil {
		glog.Errorf("[cpumanager] AddContainer error: %v", err)
		m.Unlock()
		return err
	}
	cpus := m.state.GetCPUSetOrDefault(containerID)
	m.Unlock()

	if !cpus.IsEmpty() {
		err = m.updateContainerCPUSet(containerID, cpus)
		if err != nil {
			glog.Errorf("[cpumanager] AddContainer error: %v", err)
			return err
		}
	} else {
		glog.V(5).Infof("[cpumanager] update container resources is skipped due to cpu set is empty")
	}

	return nil
}
```
我们可以看到`AddContainer`主要做了2件事：
1. 将containerID对应的cpuset信息写到`state`中
2. 更新container的cpuset配置

`policy_static.go`
```go
func (p *staticPolicy) AddContainer(s state.State, pod *v1.Pod, container *v1.Container, containerID string) error {
	glog.Infof("[cpumanager] static policy: AddContainer (pod: %s, container: %s, container id: %s)", pod.Name, container.Name, containerID)
	if numCPUs := guaranteedCPUs(pod, container); numCPUs != 0 {
		// container belongs in an exclusively allocated pool
		cpuset, err := p.allocateCPUs(s, numCPUs)
		if err != nil {
			glog.Errorf("[cpumanager] unable to allocate %d CPUs (container id: %s, error: %v)", numCPUs, containerID, err)
			return err
		}
		s.SetCPUSet(containerID, cpuset)
	}
	// container belongs in the shared pool (nothing to do; use default cpuset)
	return nil
}

func (p *staticPolicy) allocateCPUs(s state.State, numCPUs int) (cpuset.CPUSet, error) {
	glog.Infof("[cpumanager] allocateCpus: (numCPUs: %d)", numCPUs)
	result, err := takeByTopology(p.topology, p.assignableCPUs(s), numCPUs)
	if err != nil {
		return cpuset.NewCPUSet(), err
	}
	// Remove allocated CPUs from the shared CPUSet.
	s.SetDefaultCPUSet(s.GetDefaultCPUSet().Difference(result))

	glog.Infof("[cpumanager] allocateCPUs: returning \"%v\"", result)
	return result, nil
}
```

`state_file.go`
```go
func (sf *stateFile) SetCPUSet(containerID string, cset cpuset.CPUSet) {
	sf.Lock()
	defer sf.Unlock()
	sf.cache.SetCPUSet(containerID, cset)
	sf.storeState()
}
```
做第一件事——将cpuset信息写到`state`中时，不但要将`containerID`对应的cpuset信息写入，同时也要将这部分cpu从共享池子中拿走，这样`reconcile`的时候其他pod便也update了。同时，这部分信息不但跟新到内存cache中，同时也会写到本地磁盘。
>如果不写入磁盘，kubelet重启后变失去了当前cpu的使用情况拓扑。

### RemoveContainer
与`AddContainer`类似，cpuManager的`RemoveContainer`方法不需要去`updateContainer`，而只是需要将container使用的这部分cpu资源还回资源池；而`RemoveContainer`在`PreStopContainer`和`PostStopContainer`中都会被调用到。

`kuberuntime_container.go`
```go
func (m *kubeGenericRuntimeManager) killContainer(pod *v1.Pod, containerID kubecontainer.ContainerID, containerName string, reason string, gracePeriodOverride *int64) error {
...
	// Run internal pre-stop lifecycle hook
	if err := m.internalLifecycle.PreStopContainer(containerID.ID); err != nil {
		return err
	}
...
	err := m.runtimeService.StopContainer(containerID.ID, gracePeriod)
	if err != nil {
		glog.Errorf("Container %q termination failed with gracePeriod %d: %v", containerID.String(), gracePeriod, err)
	} else {
		glog.V(3).Infof("Container %q exited normally", containerID.String())
	}
...
	return err
}
```
`internal_container_lifecycle.go`
```go
func (i *internalContainerLifecycleImpl) PreStopContainer(containerID string) error {
	if utilfeature.DefaultFeatureGate.Enabled(kubefeatures.CPUManager) {
		return i.cpuManager.RemoveContainer(containerID)
	}
	return nil
}

func (i *internalContainerLifecycleImpl) PostStopContainer(containerID string) error {
	if utilfeature.DefaultFeatureGate.Enabled(kubefeatures.CPUManager) {
		return i.cpuManager.RemoveContainer(containerID)
	}
	return nil
}
```
`cpu_manager.go`
```go
func (m *manager) RemoveContainer(containerID string) error {
	m.Lock()
	defer m.Unlock()

	err := m.policy.RemoveContainer(m.state, containerID)
	if err != nil {
		glog.Errorf("[cpumanager] RemoveContainer error: %v", err)
		return err
	}
	return nil
}
```
`policy_static.go`
```go
func (p *staticPolicy) RemoveContainer(s state.State, containerID string) error {
	glog.Infof("[cpumanager] static policy: RemoveContainer (container id: %s)", containerID)
	if toRelease, ok := s.GetCPUSet(containerID); ok {
		s.Delete(containerID)
		// Mutate the shared pool, adding released cpus.
		s.SetDefaultCPUSet(s.GetDefaultCPUSet().Union(toRelease))
	}
	return nil
}
```
# 问题思考
**Q**： Kubelet重启后cpuManager如何继续工作？

**A**：cpuManager会先从本地文件(`/var/lib/k8s/kubelet/cpu_manager_state`)中`restore`，并写入内存cache。

---

**Q**： 如果手动修改container的cpuset会如何？

**A**： Kubelet会将其重新修改回来，因为会`reconcile`。

---

**Q**：如果手动修改CFS Quota/Share呢？

**A**： 修改会保留，因为`reconcile`只会更新`cpuset`。

# 总结
以上，大致梳理了kubelet的cpuManager大致工作流程，以及设计的目的和意图，限于篇幅不能面面俱到或是过于详尽，读者可以在阅读代码时细细思考与品位。

本文代码分析使用的是v1.9.11版本，在最新版本可能稍有出入。

# Reference
- https://kubernetes.io/blog/2018/07/24/feature-highlight-cpu-manager/
- [Control CPU Management Policies on the Node](https://kubernetes.io/docs/tasks/administer-cluster/cpu-management-policies/)
- [Propasal CPU Manager](https://stupefied-goodall-e282f7.netlify.com/contributors/design-proposals/node/cpu-manager/)
- [CPU Manager Phase1 PR](https://github.com/kubernetes/kubernetes/pull/49186)
- [CPU Manager Propasal PR](https://github.com/kubernetes/community/pull/654)
