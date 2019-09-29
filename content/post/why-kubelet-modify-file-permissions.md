---
title: "Why Does Kubelet Modify File Permissions"
date: 2019-09-29T16:06:44+08:00
keywords: ["kubelet", "volume"]
tags: ["kubernetes", "kubelet"]
categories: ["trouble shooting"]
summary: "Recently, I found an interesting effect. I have some pods which use flexVolume,
and after pods are *Running*, I'll put some **readOnly** files in this volume
directory. The intersting part is that these files will become **writable** every
time after kubelet being restarted."
---

## Background

Recently, I found an interesting effect. I have some pods which use flexVolume,
and after pods are *Running*, I'll put some **readOnly** files in this volume
directory. The intersting part is that these files will become **writable** every
time after kubelet being restarted.

- Before kubelet restarts
```bash
-rw-r--r-- 1 root 2000 0 Sep 27 11:03 test1
---------- 1 root 2000 0 Sep 27 11:03 test2
-r----x--- 1 root 2000 0 Sep 27 11:03 test3
---x--x--x 1 root 2000 0 Sep 27 11:03 test4
-r--r----- 1 root 2000 0 Sep 27 11:03 test5
-rw-rw---- 1 root 2000 0 Sep 27 11:05 test6
```
- After kubelet restarts
```bash
-rw-rw-r-- 1 root 2000 0 Sep 27 11:03 test1
-rw-rw---- 1 root 2000 0 Sep 27 11:03 test2
-rw-rwx--- 1 root 2000 0 Sep 27 11:03 test3
-rwxrwx--x 1 root 2000 0 Sep 27 11:03 test4
-rw-rw---- 1 root 2000 0 Sep 27 11:03 test5
-rw-rw---- 1 root 2000 0 Sep 27 11:05 test6
```
```bash
  File: ‘test1’
  Size: 0         	Blocks: 0          IO Block: 4096   regular empty file
Device: fd01h/64769d	Inode: 404813664   Links: 1
Access: (0664/-rw-rw-r--)  Uid: (    0/    root)   Gid: ( 2000/ UNKNOWN)
Access: 2019-09-27 11:03:57.045523223 +0800
Modify: 2019-09-27 11:03:57.045523223 +0800
Change: 2019-09-27 11:07:21.387847127 +0800
 Birth: -
```

## Trouble Shooting
I failed finding something valuable after tracking kubelet logs. So I decide to
search the root cause in kubelet source code.

Fortunately, I found the code where kubelet does change the files' permissions.
`pkg/volume/flexvolume/mounter.go`
```go
// SetUpAt creates new directory.
func (f *flexVolumeMounter) SetUpAt(dir string, fsGroup *int64) error {
	// Mount only once.
	alreadyMounted, err := prepareForMount(f.mounter, dir)
	if err != nil {
		return err
	}
	if alreadyMounted {
		return nil
	}

	call := f.plugin.NewDriverCall(mountCmd)

	// Interface parameters
	call.Append(dir)

	extraOptions := make(map[string]string)

	// pod metadata
	extraOptions[optionKeyPodName] = f.podName
	extraOptions[optionKeyPodNamespace] = f.podNamespace
	extraOptions[optionKeyPodUID] = string(f.podUID)
	// service account metadata
	extraOptions[optionKeyServiceAccountName] = f.podServiceAccountName

	// Extract secret and pass it as options.
	if err := addSecretsToOptions(extraOptions, f.spec, f.podNamespace, f.driverName, f.plugin.host); err != nil {
		os.Remove(dir)
		return err
	}

	// Implicit parameters
	if fsGroup != nil {
		extraOptions[optionFSGroup] = strconv.FormatInt(int64(*fsGroup), 10)
	}

	call.AppendSpec(f.spec, f.plugin.host, extraOptions)

	_, err = call.Run()
	if isCmdNotSupportedErr(err) {
		err = (*mounterDefaults)(f).SetUpAt(dir, fsGroup)
	}

	if err != nil {
		os.Remove(dir)
		return err
	}

	if !f.readOnly {
		if f.plugin.capabilities.FSGroup {
			volume.SetVolumeOwnership(f, fsGroup)
		}
	}

	return nil
}
```

The key point is on *line N. 51*, which will `SetVolumeOwnership` when volume is not `readOnly`
and pod seted `FSGroup`.

In function `SetVolumeOwnership`, we can see that kubelet modifies file
permissions by `OR 0440`.
`pkg/volume/volume_linux.go`
```go
const (
	rwMask = os.FileMode(0660)
	roMask = os.FileMode(0440)
)

// SetVolumeOwnership modifies the given volume to be owned by
// fsGroup, and sets SetGid so that newly created files are owned by
// fsGroup. If fsGroup is nil nothing is done.
func SetVolumeOwnership(mounter Mounter, fsGroup *int64) error {

	if fsGroup == nil {
		return nil
	}

	return filepath.Walk(mounter.GetPath(), func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		// chown and chmod pass through to the underlying file for symlinks.
		// Symlinks have a mode of 777 but this really doesn't mean anything.
		// The permissions of the underlying file are what matter.
		// However, if one reads the mode of a symlink then chmods the symlink
		// with that mode, it changes the mode of the underlying file, overridden
		// the defaultMode and permissions initialized by the volume plugin, which
		// is not what we want; thus, we skip chown/chmod for symlinks.
		if info.Mode()&os.ModeSymlink != 0 {
			return nil
		}

		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok {
			return nil
		}

		if stat == nil {
			klog.Errorf("Got nil stat_t for path %v while setting ownership of volume", path)
			return nil
		}

		err = os.Chown(path, int(stat.Uid), int(*fsGroup))
		if err != nil {
			klog.Errorf("Chown failed on %v: %v", path, err)
		}

		mask := rwMask
		if mounter.GetAttributes().ReadOnly {
			mask = roMask
		}

		if info.IsDir() {
			mask |= os.ModeSetgid
		}

		err = os.Chmod(path, info.Mode()|mask)
		if err != nil {
			klog.Errorf("Chmod failed on %v: %v", path, err)
		}

		return nil
	})
}
```

And in `PodSecurityContext` struct, we can find the comments which already point
out this case.
```go
type PodSecurityContext struct {
    ...
    // A special supplemental group that applies to all containers in a pod.
    // Some volume types allow the Kubelet to change the ownership of that volume
    // to be owned by the pod:
    //
    // 1. The owning GID will be the FSGroup
    // 2. The setgid bit is set (new files created in the volume will be owned by FSGroup)
    // 3. The permission bits are OR'd with rw-rw----
    //
    // If unset, the Kubelet will not modify the ownership and permissions of any volume.
    // +optional
    FSGroup *int64
}
```

And as it says, *Some volume types allow the Kubelet to change the ownership of
that volume*, and I found `hostPath` won't change the ownership of volume.

Why it's designed like this? I found the design proposal([Proposal Volume Plugins and Idempotency](https://github.com/kubernetes/community/blob/master/contributors/design-proposals/storage/volume-ownership-management.md)),
but still, it didn't explain what's the point to `OR 0440` to all files.

## Ref
- [Proposal Volume Plugins and Idempotency](https://github.com/kubernetes/community/blob/master/contributors/design-proposals/storage/volume-ownership-management.md)
