---
title: "当我们删除一个pod的时候，Kubelet都做了什么？"
date: 2020-03-19T16:13:58+08:00
lastmod: 2020-03-19T16:13:58+08:00
keywords: ["kubernetes", "kubelet", "source code go through"]
tags: ["kubernetes", "kubelet"]
categories: []
summary: ""
draft: true
---

Kubelet的源码相当的复杂，为了更好地理解它，我们从思考一个日常经常做的操作——删除一个pod入手，抽丝剥茧、层层分析，
尝试理解Kubelet的行为机制以及背后的设计哲学。

## 结论
讨论代码实现细节之前，先站在高处，说下Kubelet大体的操作流程。

当我们删除一个pod时，例如

```bash
kubectl delete pod <pod>
```

kube-apiserver收到请求后不会直接删除etcd中对应的pod资源，而是会设置pod资源的`.metadata.deletionTimestamp`为当前时间；
而一直watch着pod资源的Kubelet监听到这一变化后，会开始回收资源的一系列操作（删除容器、释放存储等等）；而后Kubelet
在确定所有资源成功释放后，会发送force delete请求给kube-apiserver，至此pod资源才会被正在从etcd中删除。


![kubelet-remove-pod-steps](/post/source-code-kubelet-how-kubelet-delete-pod/kubelet-remove-pod-steps.png)


## kube-apiserver更新deletionTimestamp
kube-apiserver的最终任务都是CRUD etcd中的资源信息。

当收到delete pod的请求时，有2中可能：

### force delete
```bash
kubectl delete pods <pod> --grace-period=0 --force
```
这时kube-apiserver会直接删除etcd中的元数据。
### graceful delete
默认`terminationGracePeriodSeconds`为30s，收到请求后kube-apiserver会更新
etcd中的pod信息，将pod metadata中deletionTimestamp打上当前时间。
```yaml
apiVersion: v1
kind: Pod
metadata:
  deletionGracePeriodSeconds: 30
  deletionTimestamp: "2020-03-23T20:56:25Z"
```
这也是我们删除pod时kube-apiserver首先做的事情。

就这样，kube-apiserver的工作就结束了，至于其他组件会根据pod的变化而做什么相应的操作，已经不是api-server所关心的了。
这里也体现了kubernetes设计的哲学——每个组件只负责做好自己的事。

## kubelet感知变化
Kubelet通过 *list-watch* 机制来感知pod的变化，具体是如何实现的呢，我们来仔细看看。

在 *makePodSourceConfig* 模块中，Kubelet会起一个goroutine专门监听各种来源(kube-apiserver, manifest,
http等等，这里我们主要关心kube-apiserver)的pod的变化，通过 *Merge* 方法，生成结构统一的变化信息元（结构体），并将这个
变化信息元放到一个updates channel中；而后 *syncLoop* 模块会负责从这个channel中消费。

```go
// pkg/kubelet/kubelet.go

if kubeDeps.PodConfig == nil {
    var err error
    kubeDeps.PodConfig, err = makePodSourceConfig(kubeCfg, kubeDeps, nodeName, bootstrapCheckpointPath)
    if err != nil {
        return nil, err
    }
}
```
在 *makePodSourceConfig* 方法中，重点关注watch apiserver方面。
```go
// makePodSourceConfig creates a config.PodConfig from the given
// KubeletConfiguration or returns an error.
func makePodSourceConfig(kubeCfg *kubeletconfiginternal.KubeletConfiguration, kubeDeps *Dependencies, nodeName types.NodeName, bootstrapCheckpointPath string) (*config.PodConfig, error) {

    ...

	// source of all configuration
	cfg := config.NewPodConfig(config.PodConfigNotificationIncremental, kubeDeps.Recorder)

    ...

	if kubeDeps.KubeClient != nil {
		klog.Infof("Watching apiserver")
		if updatechannel == nil {
			updatechannel = cfg.Channel(kubetypes.ApiserverSource)
		}
		config.NewSourceApiserver(kubeDeps.KubeClient, nodeName, updatechannel)
	}
	return cfg, nil
}
```
在 *cfg.Channel* 方法中最终会起一个goroutine来不断将apiserver中更新的pod信息重新整理后发送到一个channel中供Kubelet其他模块( *syncLoop* )消费
```go
// pkg/util/config/config.go
// Channel returns a channel where a configuration source
// can send updates of new configurations. Multiple calls with the same
// source will return the same channel. This allows change and state based sources
// to use the same channel. Different source names however will be treated as a
// union.
func (m *Mux) Channel(source string) chan interface{} {
	if len(source) == 0 {
		panic("Channel given an empty name")
	}
	m.sourceLock.Lock()
	defer m.sourceLock.Unlock()
	channel, exists := m.sources[source]
	if exists {
		return channel
	}
	newChannel := make(chan interface{})
	m.sources[source] = newChannel
	go wait.Until(func() { m.listen(source, newChannel) }, 0, wait.NeverStop)
	return newChannel
}
```
而 *config.NewSourceApiserver* 方法会用k8s的一个比较通用的机制 *list-watch* 来将最新的pod更新信息发送给
上面工作的goroutine中。
```go
// pkg/kubelet/config/apiserver.go
// NewSourceApiserver creates a config source that watches and pulls from the apiserver.
func NewSourceApiserver(c clientset.Interface, nodeName types.NodeName, updates chan<- interface{}) {
	lw := cache.NewListWatchFromClient(c.CoreV1().RESTClient(), "pods", metav1.NamespaceAll, fields.OneTermEqualSelector(api.PodHostField, string(nodeName)))
	newSourceApiserverFromLW(lw, updates)
}

// newSourceApiserverFromLW holds creates a config source that watches and pulls from the apiserver.
func newSourceApiserverFromLW(lw cache.ListerWatcher, updates chan<- interface{}) {
	send := func(objs []interface{}) {
		var pods []*v1.Pod
		for _, o := range objs {
			pods = append(pods, o.(*v1.Pod))
		}
		updates <- kubetypes.PodUpdate{Pods: pods, Op: kubetypes.SET, Source: kubetypes.ApiserverSource}
	}
	r := cache.NewReflector(lw, &v1.Pod{}, cache.NewUndeltaStore(send, cache.MetaNamespaceKeyFunc), 0)
	go r.Run(wait.NeverStop)
}
```
至此，Kubelet中这个从kube-apiserver中获取到pod更新的模块也任务完成了。这个模块的任务也很清晰，
只负责不断地从各个来源更新pod的最新动态，整理后将统一的信息发送到update
channel中，至于谁来消费、如何消费，也不是这个模块考虑的问题了。

>设计哲学：每个模块只做一件事，将它做好，并且尽量避免依赖关系

## Kubelet删除容器
下面来看下消费update channel中的信息，来删除容器回收资源的代码模块。

在 *syncLoopIteration* 代码模块中，Kubelet会消费来自各个channel的信息，然后根据需要去创建、更新或销毁pod。
```go
func (kl *Kubelet) syncLoopIteration(configCh <-chan kubetypes.PodUpdate, handler SyncHandler,
	syncCh <-chan time.Time, housekeepingCh <-chan time.Time, plegCh <-chan *pleg.PodLifecycleEvent) bool {
	select {
	case u, open := <-configCh:
		// Update from a config source; dispatch it to the right handler
		// callback.
		if !open {
			klog.Errorf("Update channel is closed. Exiting the sync loop.")
			return false
		}

		switch u.Op {
		case kubetypes.ADD:
			klog.V(2).Infof("SyncLoop (ADD, %q): %q", u.Source, format.Pods(u.Pods))
			// After restarting, kubelet will get all existing pods through
			// ADD as if they are new pods. These pods will then go through the
			// admission process and *may* be rejected. This can be resolved
			// once we have checkpointing.
			handler.HandlePodAdditions(u.Pods)
		case kubetypes.UPDATE:
			klog.V(2).Infof("SyncLoop (UPDATE, %q): %q", u.Source, format.PodsWithDeletionTimestamps(u.Pods))
			handler.HandlePodUpdates(u.Pods)
		case kubetypes.REMOVE:
			klog.V(2).Infof("SyncLoop (REMOVE, %q): %q", u.Source, format.Pods(u.Pods))
			handler.HandlePodRemoves(u.Pods)
		case kubetypes.RECONCILE:
			klog.V(4).Infof("SyncLoop (RECONCILE, %q): %q", u.Source, format.Pods(u.Pods))
			handler.HandlePodReconcile(u.Pods)
		case kubetypes.DELETE:
			klog.V(2).Infof("SyncLoop (DELETE, %q): %q", u.Source, format.Pods(u.Pods))
			// DELETE is treated as a UPDATE because of graceful deletion.
			handler.HandlePodUpdates(u.Pods)
		case kubetypes.RESTORE:
			klog.V(2).Infof("SyncLoop (RESTORE, %q): %q", u.Source, format.Pods(u.Pods))
			// These are pods restored from the checkpoint. Treat them as new
			// pods.
			handler.HandlePodAdditions(u.Pods)
		case kubetypes.SET:
			// TODO: Do we want to support this?
			klog.Errorf("Kubelet does not support snapshot update")
		}
    ...
}
```
我们这里主要关心来自 *configCh* 的信息，这些都是监听自kube-apiserver的。当pod被删除时，我们会得到
一个type为 *kubetypes.DELETE* 的update，Kubelet会调用 *handler.HandlePodUpdates(u.Pods)* 方法，最终会调用 *kl.killPod* 方法。
```go
// One of the following arguments must be non-nil: runningPod, status.
// TODO: Modify containerRuntime.KillPod() to accept the right arguments.
func (kl *Kubelet) killPod(pod *v1.Pod, runningPod *kubecontainer.Pod, status *kubecontainer.PodStatus, gracePeriodOverride *int64) error {
	var p kubecontainer.Pod
	if runningPod != nil {
		p = *runningPod
	} else if status != nil {
		p = kubecontainer.ConvertPodStatusToRunningPod(kl.getRuntime().Type(), status)
	} else {
		return fmt.Errorf("one of the two arguments must be non-nil: runningPod, status")
	}

	// Call the container runtime KillPod method which stops all running containers of the pod
	if err := kl.containerRuntime.killpod(pod, p, graceperiodoverride); err != nil {
		return err
	}
	if err := kl.containermanager.updateqoscgroups(); err != nil {
		klog.v(2).infof("failed to update qos cgroups while killing pod: %v", err)
	}
	return nil
}
```
至此，pod所对应的容器会被删掉，所使用的资源也会被释放，可是etcd中依然还存在 pod信息，这个信息又是什么时候，被谁删掉的呢？

## Kubelet删除Pod

Kubelet启动时会同时启动一个`statusManager`，来负责pod status的同步。
```go
// pkg/kubelet/kubelet.go
// Run starts the kubelet reacting to config updates
func (kl *Kubelet) Run(updates <-chan kubetypes.PodUpdate) {
	...
	// Start component sync loops.
	kl.statusManager.Start()
	...
}
```
```go
// pkg/kubelet/status/status_manager.go
func (m *manager) Start() {
	// Don't start the status manager if we don't have a client. This will happen
	// on the master, where the kubelet is responsible for bootstrapping the pods
	// of the master components.
	if m.kubeClient == nil {
		klog.Infof("Kubernetes client is nil, not starting status manager.")
		return
	}

	klog.Info("Starting to sync pod status with apiserver")
	//lint:ignore SA1015 Ticker can link since this is only called once and doesn't handle termination.
	syncTicker := time.Tick(syncPeriod)
	// syncPod and syncBatch share the same go routine to avoid sync races.
	go wait.Forever(func() {
		select {
		case syncRequest := <-m.podStatusChannel:
			klog.V(5).Infof("Status Manager: syncing pod: %q, with status: (%d, %v) from podStatusChannel",
				syncRequest.podUID, syncRequest.status.version, syncRequest.status.status)
			m.syncPod(syncRequest.podUID, syncRequest.status)
		case <-syncTicker:
			m.syncBatch()
		}
	}, 0)
}
```
主要同步工作在 *syncPod* 方法中
```go
// pkg/kubelet/status/status_manager.go
// syncPod syncs the given status with the API server. The caller must not hold the lock.
func (m *manager) syncPod(uid types.UID, status versionedPodStatus) {
	...

	// We don't handle graceful deletion of mirror pods.
	if m.canBeDeleted(pod, status.status) {
		deleteOptions := metav1.NewDeleteOptions(0)
		// Use the pod UID as the precondition for deletion to prevent deleting a newly created pod with the same name and namespace.
		deleteOptions.Preconditions = metav1.NewUIDPreconditions(string(pod.UID))
		err = m.kubeClient.CoreV1().Pods(pod.Namespace).Delete(pod.Name, deleteOptions)
		if err != nil {
			klog.Warningf("Failed to delete status for pod %q: %v", format.Pod(pod), err)
			return
		}
		klog.V(3).Infof("Pod %q fully terminated and removed from etcd", format.Pod(pod))
		m.deletePodStatus(uid)
	}
}
```
可以看到，在 *syncPod* 方法中只要Kubelet认为 *canBeDeleted* ，那么就会 *force delete* 这个pod，那怎样算是 *canBeDeleted* 能？
```go
func (m *manager) canBeDeleted(pod *v1.Pod, status v1.PodStatus) bool {
	if pod.DeletionTimestamp == nil || kubetypes.IsMirrorPod(pod) {
		return false
	}
	return m.podDeletionSafety.PodResourcesAreReclaimed(pod, status)
}
```
```go
// pkg/kubelet/kubelet_pods.go
// PodResourcesAreReclaimed returns true if all required node-level resources that a pod was consuming have
// been reclaimed by the kubelet.  Reclaiming resources is a prerequisite to deleting a pod from the API server.
func (kl *Kubelet) PodResourcesAreReclaimed(pod *v1.Pod, status v1.PodStatus) bool {
	if !notRunning(status.ContainerStatuses) {
		// We shouldn't delete pods that still have running containers
		klog.V(3).Infof("Pod %q is terminated, but some containers are still running", format.Pod(pod))
		return false
	}
	// pod's containers should be deleted
	runtimeStatus, err := kl.podCache.Get(pod.UID)
	if err != nil {
		klog.V(3).Infof("Pod %q is terminated, Error getting runtimeStatus from the podCache: %s", format.Pod(pod), err)
		return false
	}
	if len(runtimeStatus.ContainerStatuses) > 0 {
		var statusStr string
		for _, status := range runtimeStatus.ContainerStatuses {
			statusStr += fmt.Sprintf("%+v ", *status)
		}
		klog.V(3).Infof("Pod %q is terminated, but some containers have not been cleaned up: %s", format.Pod(pod), statusStr)
		return false
	}
	if kl.podVolumesExist(pod.UID) && !kl.keepTerminatedPodVolumes {
		// We shouldn't delete pods whose volumes have not been cleaned up if we are not keeping terminated pod volumes
		klog.V(3).Infof("Pod %q is terminated, but some volumes have not been cleaned up", format.Pod(pod))
		return false
	}
	if kl.kubeletConfiguration.CgroupsPerQOS {
		pcm := kl.containerManager.NewPodContainerManager()
		if pcm.Exists(pod) {
			klog.V(3).Infof("Pod %q is terminated, but pod cgroup sandbox has not been cleaned up", format.Pod(pod))
			return false
		}
	}
	return true
}
```
原来，Kubelet要确认所有container都被delete了，volume等资源也释放了，才算是 *canBeDeleted* ，才会去真正地delete pod资源。

至此，删除一个pod的过程就算基本完成了，当然Kubelet也会有一些机制（如housekeeping），来保证一些异常情况的清理工作，
保证集群的状态使用与期望的保持一致。
