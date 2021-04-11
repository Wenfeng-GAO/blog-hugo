---
title: "K8s Informer Mechanics (Part I)"
date: 2021-02-05T11:32:21+08:00
lastmod: 2021-02-05T11:32:21+08:00
keywords: ["kubernetes", "client-go", "informer", "sourcecode"]
tags: ["kubernetes", "client-go"]
categories: []
summary: "为了能实时从apiserver获取资源的状态及变化，又最大限度得降低apiserver工作负载，k8s 使用了一种叫informer的机制，通过精妙的设计，无需任何中间件，只依靠最简单的http协议 便实现了需求。informer机制是如何工作的呢？"
---

# 前言

为了能实时从apiserver获取资源的状态及变化，又最大限度得降低apiserver工作负载，k8s
使用了一种叫informer的机制，通过精妙的设计，无需任何中间件，只依靠最简单的http协议
便实现了需求。

informer机制是如何工作的呢？
它主要由几个部分组成：
1. reflector，通过listwatcher和apiserver建立连接，将监听资源的变化加入DeltaFIFO队列中；
2. DeltaFIFO，有去重能力的队列；
3. Indexer，带索引的内存Store，提供了增删改查以及索引的能力，informer会不断从DeltaFIFO上pop，并加入Indexer中；
4. Processer，用观察者模式实现的回调器

接下来会出一个informer系列博客，来逐一分析各个模块的代码实现。这篇是这个系列的第一篇，主要分析Informer在代码上如何串起各个模块来完成功能的。

# 正文

>Tips：
以下代码片段有删节，只保留作者认为跟当前讨论内容非常相关的部分。

## Informer的创建

先来看下`sharedIndexInformer`结构体中主要有哪些重要的组件。可以看到有`indexer`, `controller`, `processor`, `listerWatcher`等，之后我们会一一详细分析。
```go
type sharedIndexInformer struct {
	indexer    Indexer
	controller Controller

	processor             *sharedProcessor


	listerWatcher ListerWatcher
}
```

调用`NewSharedInformer`会创建出`SharedInformer`接口，最终调用的是`NewSharedIndexerInformer`。
```go
func NewSharedIndexInformer(lw ListerWatcher, exampleObject runtime.Object, defaultEventHandlerResyncPeriod time.Duration, indexers Indexers) SharedIndexInformer {
	realClock := &clock.RealClock{}
	sharedIndexInformer := &sharedIndexInformer{
		processor:                       &sharedProcessor{clock: realClock},
		indexer:                         NewIndexer(DeletionHandlingMetaNamespaceKeyFunc, indexers),
		listerWatcher:                   lw,
		objectType:                      exampleObject,
		resyncCheckPeriod:               defaultEventHandlerResyncPeriod,
		defaultEventHandlerResyncPeriod: defaultEventHandlerResyncPeriod,
		cacheMutationDetector:           NewCacheMutationDetector(fmt.Sprintf("%T", exampleObject)),
		clock:                           realClock,
	}
	return sharedIndexInformer
}
```
我们之前在意的几个重要组件如何创建的呢？
- indexer：函数参数传入`Indexers`，调用`NewIndexer`创建
- controller：未创建
- processor：`&sharedProcessor{}`直接初始化
- listWatcher: 作为函数参数直接传入

`NewSharedIndexInformer`方法返回`SharedIndexInformer` Interface，我们先来看下这个Interface有哪些方法。

```go
// SharedIndexInformer provides add and get Indexers ability based on SharedInformer.
type SharedIndexInformer interface {
	SharedInformer
	// AddIndexers add indexers to the informer before it starts.
	AddIndexers(indexers Indexers) error
	GetIndexer() Indexer
}

type SharedInformer interface {

	Run(stopCh <-chan struct{})

}
```

`SharedIndexInformer` Interface有很多重要方法，这里我们最关心的是它的启动方法`Run`。


## Run

在`Run`中我们可以看到
1. controller通过`s.controller = New(cfg)`被创建出来
2. deltaFIFO通过`NewDeltaFIFOWithOptions`被创建出来，同时传入cfg
3. processor通过`s.processor.run`启动
4. controller通过`s.controller.Run(stopCh)`启动
```go
func (s *sharedIndexInformer) Run(stopCh <-chan struct{}) {

	fifo := NewDeltaFIFOWithOptions(DeltaFIFOOptions{
		KnownObjects:          s.indexer,
		EmitDeltaTypeReplaced: true,
	})

	cfg := &Config{
		Queue:            fifo,
		ListerWatcher:    s.listerWatcher,
		ObjectType:       s.objectType,
		FullResyncPeriod: s.resyncCheckPeriod,
		RetryOnError:     false,
		ShouldResync:     s.processor.shouldResync,

		Process:           s.HandleDeltas,
		WatchErrorHandler: s.watchErrorHandler,
	}

	func() {
		s.startedLock.Lock()
		defer s.startedLock.Unlock()

		s.controller = New(cfg)
		s.controller.(*controller).clock = s.clock
		s.started = true
	}()

	// Separate stop channel because Processor should be stopped strictly after controller
	processorStopCh := make(chan struct{})
	var wg wait.Group
	defer wg.Wait()              // Wait for Processor to stop
	defer close(processorStopCh) // Tell Processor to stop
	wg.StartWithChannel(processorStopCh, s.cacheMutationDetector.Run)
	wg.StartWithChannel(processorStopCh, s.processor.run)

	defer func() {
		s.startedLock.Lock()
		defer s.startedLock.Unlock()
		s.stopped = true // Don't want any new listeners
	}()
	s.controller.Run(stopCh)
}
```

看下`controller.Run()`，可以看到
- reflector通过`NewReflector`创建出来，并传入了`listWatcher`和`deltaFIFO`
- reflector通过`r.Run`执行
- controller执行`processLoop`
```go
func (c *controller) Run(stopCh <-chan struct{}) {
	defer utilruntime.HandleCrash()
	go func() {
		<-stopCh
		c.config.Queue.Close()
	}()
	r := NewReflector(
		c.config.ListerWatcher,
		c.config.ObjectType,
		c.config.Queue,
		c.config.FullResyncPeriod,
	)

	c.reflectorMutex.Lock()
	c.reflector = r
	c.reflectorMutex.Unlock()

	var wg wait.Group

	wg.StartWithChannel(stopCh, r.Run)

	wait.Until(c.processLoop, time.Second, stopCh)
	wg.Wait()
}
```
reflector通过其`Run`方法向apiserver listwatch资源，并加入`deltaFIFO`中，这部分细节我们再之后详谈Reflector时再看。
现在，我们的重点还是追随controller，看看它如何工作。

```go
func (c *controller) processLoop() {
	for {
		obj, err := c.config.Queue.Pop(PopProcessFunc(c.config.Process))
		if err != nil {
			if err == ErrFIFOClosed {
				return
			}
			if c.config.RetryOnError {
				// This is the safe way to re-enqueue.
				c.config.Queue.AddIfNotPresent(obj)
			}
		}
	}
}
```
可以看到，`processLoop`方法会不断调用deltaFIFO的`Pop`方法，而`Pop`方法设计的也非常灵活，传入的是一个回调函数，这个回调函数`c.config.Process`是什么呢？
回到sharedInformer的`Run`方法中，可以看到是sharedInformer的`HandleDeltas`方法。

```go
	cfg := &Config{
		Queue:            fifo,
		ListerWatcher:    s.listerWatcher,
		ObjectType:       s.objectType,
		FullResyncPeriod: s.resyncCheckPeriod,
		RetryOnError:     false,
		ShouldResync:     s.processor.shouldResync,

		Process:           s.HandleDeltas,
		WatchErrorHandler: s.watchErrorHandler,
	}
```

`HandleDeltas`会做什么呢？当然是handle `Deltas`了。
1. 根据deltas的`Type`进行不同操作
2. 调用indexer的接口来存储并添加索引
3. 调用processor的接口`processor.distribute`来触发processor中注册的回调函数

```go
func (s *sharedIndexInformer) HandleDeltas(obj interface{}) error {
	s.blockDeltas.Lock()
	defer s.blockDeltas.Unlock()

	// from oldest to newest
	for _, d := range obj.(Deltas) {
		switch d.Type {
		case Sync, Replaced, Added, Updated:
			s.cacheMutationDetector.AddObject(d.Object)
			if old, exists, err := s.indexer.Get(d.Object); err == nil && exists {
				if err := s.indexer.Update(d.Object); err != nil {
					return err
				}

				isSync := false
				switch {
				case d.Type == Sync:
					// Sync events are only propagated to listeners that requested resync
					isSync = true
				case d.Type == Replaced:
					if accessor, err := meta.Accessor(d.Object); err == nil {
						if oldAccessor, err := meta.Accessor(old); err == nil {
							// Replaced events that didn't change resourceVersion are treated as resync events
							// and only propagated to listeners that requested resync
							isSync = accessor.GetResourceVersion() == oldAccessor.GetResourceVersion()
						}
					}
				}
				s.processor.distribute(updateNotification{oldObj: old, newObj: d.Object}, isSync)
			} else {
				if err := s.indexer.Add(d.Object); err != nil {
					return err
				}
				s.processor.distribute(addNotification{newObj: d.Object}, false)
			}
		case Deleted:
			if err := s.indexer.Delete(d.Object); err != nil {
				return err
			}
			s.processor.distribute(deleteNotification{oldObj: d.Object}, false)
		}
	}
	return nil
}
```

# 最后

至此，informer如何调用各个组件进行工作的大体流程我们已经走完。官方的配图理解各个组件后再看非常清晰，这个系列Informer Mechanics只关注与图的上半部分(client-go)。

![client-go-informer](/post/k8s-informer-mechanics/client-go-controller-interaction.jpg)

总结来说就是，reflector模块通过listwatcher和apiserver建立长连接，将资源的变化存入DeltaFIFO队列，而队列的消费端则不断从队列上pop后，用Indexer添加索引，用Processer实现回调，通知事件的注册方。