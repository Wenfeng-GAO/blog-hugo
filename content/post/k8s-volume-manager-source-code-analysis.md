---
title: "Kubernetes源码分析之VolumeManager"
date: 2019-02-28T23:07:20+08:00
keywords: ["kubernetes", "kubelet", "volumemanager", "sourcecode"]
tags: ["kubernetes", "kubelet"]
categories: ["k8s"]
---

## 前言

VolumeManager是kubernetes负责管理pod存储相关的重要组件，理解VolumeManager是理解pod生命周期的重要环节。
本文的分析基于v1.13.2版本。


## 正文

通很多其他manager一样，`volumeManager`在`NewMainKubelet`方法中生成。
```go
pkg/kubelet/kubelet.go: 329

// NewMainKubelet instantiates a new Kubelet object along with all the required internal modules.
// No initialization of Kubelet and its modules should happen here.
func NewMainKubelet(...) (*Kubelet, error) {
  ...
  // setup volumeManager
	klet.volumeManager = volumemanager.NewVolumeManager(
		kubeCfg.EnableControllerAttachDetach,
		nodeName,
		klet.podManager,
		klet.statusManager,
		klet.kubeClient,
		klet.volumePluginMgr,
		klet.containerRuntime,
		kubeDeps.Mounter,
		klet.getPodsDir(),
		kubeDeps.Recorder,
		experimentalCheckNodeCapabilitiesBeforeMount,
		keepTerminatedPodVolumes)
  ...
	return klet, nil
}
```
```go
/pkg/kubelet/volumemanager/volume_manager.go: 149

// NewVolumeManager returns a new concrete instance implementing the
// VolumeManager interface.
//
// kubeClient - kubeClient is the kube API client used by DesiredStateOfWorldPopulator
//   to communicate with the API server to fetch PV and PVC objects
// volumePluginMgr - the volume plugin manager used to access volume plugins.
//   Must be pre-initialized.
func NewVolumeManager(
	controllerAttachDetachEnabled bool,
	nodeName k8stypes.NodeName,
	podManager pod.Manager,
	podStatusProvider status.PodStatusProvider,
	kubeClient clientset.Interface,
	volumePluginMgr *volume.VolumePluginMgr,
	kubeContainerRuntime container.Runtime,
	mounter mount.Interface,
	kubeletPodsDir string,
	recorder record.EventRecorder,
	checkNodeCapabilitiesBeforeMount bool,
	keepTerminatedPodVolumes bool) VolumeManager {

	vm := &volumeManager{
		kubeClient:          kubeClient,
		volumePluginMgr:     volumePluginMgr,
		desiredStateOfWorld: cache.NewDesiredStateOfWorld(volumePluginMgr),
		actualStateOfWorld:  cache.NewActualStateOfWorld(nodeName, volumePluginMgr),
		operationExecutor: operationexecutor.NewOperationExecutor(operationexecutor.NewOperationGenerator(
			kubeClient,
			volumePluginMgr,
			recorder,
			checkNodeCapabilitiesBeforeMount,
			volumepathhandler.NewBlockVolumePathHandler())),
	}

	vm.desiredStateOfWorldPopulator = populator.NewDesiredStateOfWorldPopulator(
		kubeClient,
		desiredStateOfWorldPopulatorLoopSleepPeriod,
		desiredStateOfWorldPopulatorGetPodStatusRetryDuration,
		podManager,
		podStatusProvider,
		vm.desiredStateOfWorld,
		vm.actualStateOfWorld,
		kubeContainerRuntime,
		keepTerminatedPodVolumes)
	vm.reconciler = reconciler.NewReconciler(
		kubeClient,
		controllerAttachDetachEnabled,
		reconcilerLoopSleepPeriod,
		reconcilerSyncStatesSleepPeriod,
		waitForAttachTimeout,
		nodeName,
		vm.desiredStateOfWorld,
		vm.actualStateOfWorld,
		vm.desiredStateOfWorldPopulator.HasAddedPods,
		vm.operationExecutor,
		mounter,
		volumePluginMgr,
		kubeletPodsDir)

	return vm
}
```
在kubelet `Run`方法中会启动`volumeManager`。
```go
/pkg/kubelet/kubelet.go: 1407

// Run starts the kubelet reacting to config updates
func (kl *Kubelet) Run(updates <-chan kubetypes.PodUpdate) {
	...

	// Start volume manager
	go kl.volumeManager.Run(kl.sourcesReady, wait.NeverStop)

	...

	// Start the pod lifecycle event generator.
	kl.pleg.Start()
	kl.syncLoop(updates, kl)
}
```
`volumeManager.Run`方法主要会用goroutine的方式执行2个重要的方法`desiredStateOfWorldPopulator.Run`和`reconciler.Run`。
```go
/pkg/kubelet/volumemanager/volume_manager.go: 242

func (vm *volumeManager) Run(sourcesReady config.SourcesReady, stopCh <-chan struct{}) {
	defer runtime.HandleCrash()

	go vm.desiredStateOfWorldPopulator.Run(sourcesReady, stopCh)
	klog.V(2).Infof("The desired_state_of_world populator starts")

	klog.Infof("Starting Kubelet Volume Manager")
	go vm.reconciler.Run(stopCh)

	metrics.Register(vm.actualStateOfWorld, vm.desiredStateOfWorld, vm.volumePluginMgr)

	<-stopCh
	klog.Infof("Shutting down Kubelet Volume Manager")
}
```
### DesiredStateOfWorldPopulator
`DesiredStateOfWorldPopulator`遍历所有pod，确保有volume的pod都会存在在desired world cache中，或者将已经不存在的pod从cache中删除，保证cache的实时性。
```go
/pkg/kubelet/volumemanager/populator/desired_state_of_world_populator.go: 128

func (dswp *desiredStateOfWorldPopulator) Run(sourcesReady config.SourcesReady, stopCh <-chan struct{}) {
	// Wait for the completion of a loop that started after sources are all ready, then set hasAddedPods accordingly
	klog.Infof("Desired state populator starts to run")
	wait.PollUntil(dswp.loopSleepDuration, func() (bool, error) {
		done := sourcesReady.AllReady()
		dswp.populatorLoop()
		return done, nil
	}, stopCh)
	dswp.hasAddedPodsLock.Lock()
	dswp.hasAddedPods = true
	dswp.hasAddedPodsLock.Unlock()
	wait.Until(dswp.populatorLoop, dswp.loopSleepDuration, stopCh)
}
```
```go
/pkg/kubelet/volumemanager/populator/desired_state_of_world_populator.go: 153

func (dswp *desiredStateOfWorldPopulator) populatorLoop() {
	dswp.findAndAddNewPods()

	// findAndRemoveDeletedPods() calls out to the container runtime to
	// determine if the containers for a given pod are terminated. This is
	// an expensive operation, therefore we limit the rate that
	// findAndRemoveDeletedPods() is called independently of the main
	// populator loop.
	if time.Since(dswp.timeOfLastGetPodStatus) < dswp.getPodStatusRetryDuration {
		klog.V(5).Infof(
			"Skipping findAndRemoveDeletedPods(). Not permitted until %v (getPodStatusRetryDuration %v).",
			dswp.timeOfLastGetPodStatus.Add(dswp.getPodStatusRetryDuration),
			dswp.getPodStatusRetryDuration)

		return
	}

	dswp.findAndRemoveDeletedPods()
}
```

## Reconciler
`Reconciler`会不断查看`actual state of the world`和`desired state of the world`是否一致，如果不一致，就通过`mount/unmount/attach/detach`等操作来保证一致.

```go
/pkg/kubelet/volumemanager/reconciler/reconsiler.go: 142

func (rc *reconciler) Run(stopCh <-chan struct{}) {
	wait.Until(rc.reconciliationLoopFunc(), rc.loopSleepDuration, stopCh)
}

func (rc *reconciler) reconciliationLoopFunc() func() {
	return func() {
		rc.reconcile()

		// Sync the state with the reality once after all existing pods are added to the desired state from all sources.
		// Otherwise, the reconstruct process may clean up pods' volumes that are still in use because
		// desired state of world does not contain a complete list of pods.
		if rc.populatorHasAddedPods() && !rc.StatesHasBeenSynced() {
			klog.Infof("Reconciler: start to sync state")
			rc.sync()
		}
	}
}
```
`reconciler`会保证*real world*与*desired world*的一致性。
```go
/pkg/kubelet/volumemanager/reconciler/reconciler.go: 160

func (rc *reconciler) reconcile() {
	// Unmounts are triggered before mounts so that a volume that was
	// referenced by a pod that was deleted and is now referenced by another
	// pod is unmounted from the first pod before being mounted to the new
	// pod.

	// Ensure volumes that should be unmounted are unmounted.
	for _, mountedVolume := range rc.actualStateOfWorld.GetMountedVolumes() {
		if !rc.desiredStateOfWorld.PodExistsInVolume(mountedVolume.PodName, mountedVolume.VolumeName) {
			// Volume is mounted, unmount it
			klog.V(5).Infof(mountedVolume.GenerateMsgDetailed("Starting operationExecutor.UnmountVolume", ""))
			err := rc.operationExecutor.UnmountVolume(
				mountedVolume.MountedVolume, rc.actualStateOfWorld, rc.kubeletPodsDir)
			if err != nil &&
				!nestedpendingoperations.IsAlreadyExists(err) &&
				!exponentialbackoff.IsExponentialBackoff(err) {
				// Ignore nestedpendingoperations.IsAlreadyExists and exponentialbackoff.IsExponentialBackoff errors, they are expected.
				// Log all other errors.
				klog.Errorf(mountedVolume.GenerateErrorDetailed(fmt.Sprintf("operationExecutor.UnmountVolume failed (controllerAttachDetachEnabled %v)", rc.controllerAttachDetachEnabled), err).Error())
			}
			if err == nil {
				klog.Infof(mountedVolume.GenerateMsgDetailed("operationExecutor.UnmountVolume started", ""))
			}
		}
	}

	// Ensure volumes that should be attached/mounted are attached/mounted.
	for _, volumeToMount := range rc.desiredStateOfWorld.GetVolumesToMount() {
		volMounted, devicePath, err := rc.actualStateOfWorld.PodExistsInVolume(volumeToMount.PodName, volumeToMount.VolumeName)
		volumeToMount.DevicePath = devicePath
		if cache.IsVolumeNotAttachedError(err) {
			if rc.controllerAttachDetachEnabled || !volumeToMount.PluginIsAttachable {
				// Volume is not attached (or doesn't implement attacher), kubelet attach is disabled, wait
				// for controller to finish attaching volume.
				klog.V(5).Infof(volumeToMount.GenerateMsgDetailed("Starting operationExecutor.VerifyControllerAttachedVolume", ""))
				err := rc.operationExecutor.VerifyControllerAttachedVolume(
					volumeToMount.VolumeToMount,
					rc.nodeName,
					rc.actualStateOfWorld)
				if err != nil &&
					!nestedpendingoperations.IsAlreadyExists(err) &&
					!exponentialbackoff.IsExponentialBackoff(err) {
					// Ignore nestedpendingoperations.IsAlreadyExists and exponentialbackoff.IsExponentialBackoff errors, they are expected.
					// Log all other errors.
					klog.Errorf(volumeToMount.GenerateErrorDetailed(fmt.Sprintf("operationExecutor.VerifyControllerAttachedVolume failed (controllerAttachDetachEnabled %v)", rc.controllerAttachDetachEnabled), err).Error())
				}
				if err == nil {
					klog.Infof(volumeToMount.GenerateMsgDetailed("operationExecutor.VerifyControllerAttachedVolume started", ""))
				}
			} else {
				// Volume is not attached to node, kubelet attach is enabled, volume implements an attacher,
				// so attach it
				volumeToAttach := operationexecutor.VolumeToAttach{
					VolumeName: volumeToMount.VolumeName,
					VolumeSpec: volumeToMount.VolumeSpec,
					NodeName:   rc.nodeName,
				}
				klog.V(5).Infof(volumeToAttach.GenerateMsgDetailed("Starting operationExecutor.AttachVolume", ""))
				err := rc.operationExecutor.AttachVolume(volumeToAttach, rc.actualStateOfWorld)
				if err != nil &&
					!nestedpendingoperations.IsAlreadyExists(err) &&
					!exponentialbackoff.IsExponentialBackoff(err) {
					// Ignore nestedpendingoperations.IsAlreadyExists and exponentialbackoff.IsExponentialBackoff errors, they are expected.
					// Log all other errors.
					klog.Errorf(volumeToMount.GenerateErrorDetailed(fmt.Sprintf("operationExecutor.AttachVolume failed (controllerAttachDetachEnabled %v)", rc.controllerAttachDetachEnabled), err).Error())
				}
				if err == nil {
					klog.Infof(volumeToMount.GenerateMsgDetailed("operationExecutor.AttachVolume started", ""))
				}
			}
		} else if !volMounted || cache.IsRemountRequiredError(err) {
			// Volume is not mounted, or is already mounted, but requires remounting
			remountingLogStr := ""
			isRemount := cache.IsRemountRequiredError(err)
			if isRemount {
				remountingLogStr = "Volume is already mounted to pod, but remount was requested."
			}
			klog.V(4).Infof(volumeToMount.GenerateMsgDetailed("Starting operationExecutor.MountVolume", remountingLogStr))
			err := rc.operationExecutor.MountVolume(
				rc.waitForAttachTimeout,
				volumeToMount.VolumeToMount,
				rc.actualStateOfWorld,
				isRemount)
			if err != nil &&
				!nestedpendingoperations.IsAlreadyExists(err) &&
				!exponentialbackoff.IsExponentialBackoff(err) {
				// Ignore nestedpendingoperations.IsAlreadyExists and exponentialbackoff.IsExponentialBackoff errors, they are expected.
				// Log all other errors.
				klog.Errorf(volumeToMount.GenerateErrorDetailed(fmt.Sprintf("operationExecutor.MountVolume failed (controllerAttachDetachEnabled %v)", rc.controllerAttachDetachEnabled), err).Error())
			}
			if err == nil {
				if remountingLogStr == "" {
					klog.V(1).Infof(volumeToMount.GenerateMsgDetailed("operationExecutor.MountVolume started", remountingLogStr))
				} else {
					klog.V(5).Infof(volumeToMount.GenerateMsgDetailed("operationExecutor.MountVolume started", remountingLogStr))
				}
			}
		} else if cache.IsFSResizeRequiredError(err) &&
			utilfeature.DefaultFeatureGate.Enabled(features.ExpandInUsePersistentVolumes) {
			klog.V(4).Infof(volumeToMount.GenerateMsgDetailed("Starting operationExecutor.ExpandVolumeFSWithoutUnmounting", ""))
			err := rc.operationExecutor.ExpandVolumeFSWithoutUnmounting(
				volumeToMount.VolumeToMount,
				rc.actualStateOfWorld)
			if err != nil &&
				!nestedpendingoperations.IsAlreadyExists(err) &&
				!exponentialbackoff.IsExponentialBackoff(err) {
				// Ignore nestedpendingoperations.IsAlreadyExists and exponentialbackoff.IsExponentialBackoff errors, they are expected.
				// Log all other errors.
				klog.Errorf(volumeToMount.GenerateErrorDetailed("operationExecutor.ExpandVolumeFSWithoutUnmounting failed", err).Error())
			}
			if err == nil {
				klog.V(4).Infof(volumeToMount.GenerateMsgDetailed("operationExecutor.ExpandVolumeFSWithoutUnmounting started", ""))
			}
		}
	}

	// Ensure devices that should be detached/unmounted are detached/unmounted.
	for _, attachedVolume := range rc.actualStateOfWorld.GetUnmountedVolumes() {
		// Check IsOperationPending to avoid marking a volume as detached if it's in the process of mounting.
		if !rc.desiredStateOfWorld.VolumeExists(attachedVolume.VolumeName) &&
			!rc.operationExecutor.IsOperationPending(attachedVolume.VolumeName, nestedpendingoperations.EmptyUniquePodName) {
			if attachedVolume.GloballyMounted {
				// Volume is globally mounted to device, unmount it
				klog.V(5).Infof(attachedVolume.GenerateMsgDetailed("Starting operationExecutor.UnmountDevice", ""))
				err := rc.operationExecutor.UnmountDevice(
					attachedVolume.AttachedVolume, rc.actualStateOfWorld, rc.mounter)
				if err != nil &&
					!nestedpendingoperations.IsAlreadyExists(err) &&
					!exponentialbackoff.IsExponentialBackoff(err) {
					// Ignore nestedpendingoperations.IsAlreadyExists and exponentialbackoff.IsExponentialBackoff errors, they are expected.
					// Log all other errors.
					klog.Errorf(attachedVolume.GenerateErrorDetailed(fmt.Sprintf("operationExecutor.UnmountDevice failed (controllerAttachDetachEnabled %v)", rc.controllerAttachDetachEnabled), err).Error())
				}
				if err == nil {
					klog.Infof(attachedVolume.GenerateMsgDetailed("operationExecutor.UnmountDevice started", ""))
				}
			} else {
				// Volume is attached to node, detach it
				// Kubelet not responsible for detaching or this volume has a non-attachable volume plugin.
				if rc.controllerAttachDetachEnabled || !attachedVolume.PluginIsAttachable {
					rc.actualStateOfWorld.MarkVolumeAsDetached(attachedVolume.VolumeName, attachedVolume.NodeName)
					klog.Infof(attachedVolume.GenerateMsgDetailed("Volume detached", fmt.Sprintf("DevicePath %q", attachedVolume.DevicePath)))
				} else {
					// Only detach if kubelet detach is enabled
					klog.V(5).Infof(attachedVolume.GenerateMsgDetailed("Starting operationExecutor.DetachVolume", ""))
					err := rc.operationExecutor.DetachVolume(
						attachedVolume.AttachedVolume, false /* verifySafeToDetach */, rc.actualStateOfWorld)
					if err != nil &&
						!nestedpendingoperations.IsAlreadyExists(err) &&
						!exponentialbackoff.IsExponentialBackoff(err) {
						// Ignore nestedpendingoperations.IsAlreadyExists && exponentialbackoff.IsExponentialBackoff errors, they are expected.
						// Log all other errors.
						klog.Errorf(attachedVolume.GenerateErrorDetailed(fmt.Sprintf("operationExecutor.DetachVolume failed (controllerAttachDetachEnabled %v)", rc.controllerAttachDetachEnabled), err).Error())
					}
					if err == nil {
						klog.Infof(attachedVolume.GenerateMsgDetailed("operationExecutor.DetachVolume started", ""))
					}
				}
			}
		}
	}
}
```

`rc.sync()`只会执行1次，为了避免kubelet重启等行为期间有数据的不一致。它会扫描所有pod的volume目录，如果有不一致，将*actual world*和*desired world*的数据都补齐。

```go
/pkg/kubelet/volumemanager/reconciler/reconciler.go: 328

// sync process tries to observe the real world by scanning all pods' volume directories from the disk.
// If the actual and desired state of worlds are not consistent with the observed world, it means that some
// mounted volumes are left out probably during kubelet restart. This process will reconstruct
// the volumes and update the actual and desired states. For the volumes that cannot support reconstruction,
// it will try to clean up the mount paths with operation executor.
func (rc *reconciler) sync() {
	defer rc.updateLastSyncTime()
	rc.syncStates()
}
```

## 总结
VolumeManager是负责k8s存储的核心组件，它不但为其他组件提供存储方面的调用接口，同时也通过`desired world`、`actual world`、`reconciler`等机制，实现完整的、闭环的存储管理。

分析VolumeManager的相关代码，不但可以了解k8s的实现原理，还能对设计模式有所体悟和思考。

## Ref
- https://blog.csdn.net/zhonglinzhang/article/details/82800287
