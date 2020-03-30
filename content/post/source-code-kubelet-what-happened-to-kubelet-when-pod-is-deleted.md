---
title: "What Happened to Kubelet When Pod Is Deleted"
date: 2020-03-26T04:11:32+08:00
lastmod: 2020-03-31T04:11:32+08:00
keywords: ["kubernetes", "kubelet", "source code go through"]
tags: ["kubernetes", "kubelet"]
categories: []
summary: ""
---

The source code of Kubelet is quite complicated. In order to better understand
it, we start by thinking about an operation we


## Conclusion
Before discussing the implementation details of the source code, let's stand
high and talk about the general process that Kubelet will make.

For example, we start by deleting a pod.

```bash
kubectl delete pod <pod>
```

kube-apiserver won't directly delete the corresponding pod resource in etcd
after receiving the deletion request, but will set the `.metadata.deletionTimestamp` of pod to current time.

On the mean time, Kubelet, who is `watching` the pod resource from
kube-apiserver, will start a series of operations to recycle computing
resources(such as deleting containers, releasing storages, etc.). As soon as
Kubelet makes sure resources are successfully released, it will send a force
deletion request to kube-apiserver, at which point the pod resource will be
really deleted from etcd.

![kubelet-remove-pod-steps](/post/source-code-kubelet-how-kubelet-delete-pod/kubelet-remove-pod-steps.png)

## kube-apiserver update deletionTimestamp
The most fundamental task of kube-apiserver is to `CRUD` resources in etcd.

When receiving a deletion request, there're 2 possibilities:
### force delete
```bash
kubectl delete pods <pod> --grace-period=0 --force
```
In this case, kube-apiserver will delete the metadata in etcd directly.

### graceful delete
After receiving request, rather than delete directly, kube-apiserver will update `deletionTimestamp` of pod metadata to current time.
```yaml
apiVersion: v1
kind: Pod
metadata:
  deletionGracePeriodSeconds: 30
  deletionTimestamp: "2020-03-23T20:56:25Z"
```

This is also the default thing kube-apiserver does when we delete a pod
normally.

In this way, kube-apiserver finishes its work, and it's no longer
kube-apiserver's concern as for what the other components will do according to
the pod changes.

Here also reflects the design philosophy of Kubernetes, each component is only
responsible for doing its own job.

## Watch by Kubelet
Kubelet uses the *list-watch* mechanism to sense changes in of the pod. How does it work? Let's take a closer look.

In the *makePodSourceConfig* module, Kubelet will set up a goroutine to listen to various sources of changes of pods(kube-apiserver, manifest, http etc., here we are mainly concerned about changes from the kube-apiserver).

Then through the *Merge* method, it generates a uniformed metadata structure, and
put it into an updates channel, then the *syncLoop* module is responsible for
consuming from this channel.
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
In the *makePodSourceConfig* method, we focus on the aspect of waching
apiserver.
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
In the *cfg.Channel* method, a goroutine will eventually be created to continuously rearrange the info of updated pods from kube-apiserver and send it to a channel for consumption by other module (*syncLoop*).
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
Meanwhile, the *config.NewSourceApiserver* method will use a general mechanism of k8s (*list-watch*) to send the latest pod update info to the goroutine working above.
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
At this point, the module that obtains pod's updates from kube-apiserver has also completed its task. 

The task of this module is clear as well: only responsible for continuously updating the latest updates of pods from various sources, and sending unified information to *update* channel.

As to who consumes from the *update* channel or how to consume it, it's not the business of this module any longer.

> Do one thing per module, do it well, and try to avoid dependencies.

## Delete containers
Let's take a look at the module that consumes the information from the *update* channel l, which will delete the containers of deleted pod.

In the *syncLoopIteration* module, Kubelet consumes information from various channels and then creates, updates, or destroys pods as needed.
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
Here we are mainly concerned about the information from *configCh*, which are all wathed from kube-apiserver.

When the pod is deleted, Kubelet receives an update of type *kubetypes.DELETE*, then it will call *handler.HandlePodUpdates (u.Pods)* method, which will eventually call the *kl.killPod* method.
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

From now on, containers corresponding to the pod will be deleted, and the resources used will also be released. 

However, the pod metadata still exists in etcd. When will this metadata be
deleted and by which component? Let's take a look.

## Force delete pod
Kubelet starts a `statusManager` at the same time when it starts, which is responsible for the synchronization of pod status.
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
The main synchronization works lies in *syncPod* methods.
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
As we can see in the *syncPod* method, Kubelet will *force delete pod* as long
as it thinks the pod *canBeDeleted*. So what means *canBeDeleted* exactly?
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
It turns out that Kubelet needs to confirm that all containers are dead, and resources such as volume have been released, etc.

Finally, the process of deleting a pod is almost finished. Of course there're
some other mechanisms such as housekeeping to ensure everything goes right in
Kubelet's responsibility. We've basically understood what happened to Kubelet
when a pod is normally deleted. And by go through the source code, we feel some
of design philosophy in kubernetes as well. 
