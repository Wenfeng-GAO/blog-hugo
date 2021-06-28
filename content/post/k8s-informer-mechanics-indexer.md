---
title: "K8s Informer Mechanics Part IV - Indexer"
date: 2021-06-28T12:09:27+08:00
lastmod: 2021-06-28T12:10:27+08:00
keywords: ["kubernetes", "client-go", "informer", "sourcecode", "indexer"]
tags: ["kubernetes", "client-go"]
categories: ["k8s"]
summary: "为了能实时从apiserver获取资源的状态及变化，又最大限度得降低apiserver工作负载，k8s 使用了一种叫informer的机制，通过精妙的设计，无需任何中间件，只依靠最简单的http协议 便实现了需求。作为介绍Informer机制系列文章的第四篇，我们详细分析Indexer模块的代码实现。"
---

## 前言

为了能实时从apiserver获取资源的状态及变化，又最大限度得降低apiserver工作负载，k8s
使用了一种叫informer的机制，通过精妙的设计，无需任何中间件，只依靠最简单的http协议
便实现了需求。

informer机制是如何工作的呢？
它主要由几个部分组成：
1. reflector，通过listwatcher和apiserver建立连接，将监听资源的变化加入DeltaFIFO队列中；
2. DeltaFIFO，有去重能力的队列；
3. Indexer，带索引的内存Store，提供了增删改查以及索引的能力，informer会不断从DeltaFIFO上pop，并加入Indexer中；
4. Processer，用观察者模式实现的回调器

接下来会出一个informer系列博客，来逐一分析各个模块的代码实现。这篇是这个系列的第四篇，主要分析组成informer机制的重要组件之一Indexer。

### Informer Mechanics系列
- [K8s Informer Mechanics Part I]({{< relref "/post/k8s-informer-mechanics.md" >}})
- [K8s Informer Mechanics Part II - Reflector]({{< relref "/post/k8s-informer-mechanics-reflector.md" >}})
- [K8s Informer Mechanics Part III - DeltaFIFO]({{< relref "/post/k8s-informer-mechanics-deltafifo.md" >}})
- [K8s Informer Mechanics Part IV - Indexer]({{< relref "/post/k8s-informer-mechanics-indexer.md" >}})

## 正文

>Tips：
以下代码片段有删节，只保留作者认为跟当前讨论内容非常相关的部分。

Indexer是informer的核心组件之一，是一个有索引能力的local cache。
Indexer概念里有一些名词（定义）非常容易混淆，我们首先把他们罗列出来：
- obj存在local cache中所对应的key，由Store中的KeyFunc生成，知道了key我们才能从cache中获取到对应的obj
- Index，代表一个索引，它的key/name由IndexFunc生成，有了name我们才能拿到Index的value，value是一组obj的key
- Indexers，索引器，由使用方提供name到IndexFunc的映射
- Indices，由使用方提供的name到Index的映射，此Index的name由相同name的IndexFunc生成

使用方提供了一个索引器，Indexers["my-index"] = IndexFunc1, 然后将obj加入local cache时便会生成对应的索引。
```go
indexKey := IndexFunc1(obj)
Index := Indices["my-index"]
Index[indexKey] = {KeyFunc(obj)}
```
之后，通过"my-index" 或 indexKey就可以快速找到一系列的obj。

### Indexer interface
<details>
<summary>Indexer interface源码</summary>

```go
// Indexer extends Store with multiple indices and restricts each
// accumulator to simply hold the current object (and be empty after
// Delete).
//
// There are three kinds of strings here:
// 1. a storage key, as defined in the Store interface,
// 2. a name of an index, and
// 3. an "indexed value", which is produced by an IndexFunc and
//    can be a field value or any other string computed from the object.
type Indexer interface {
	Store
	// Index returns the stored objects whose set of indexed values
	// intersects the set of indexed values of the given object, for
	// the named index
	Index(indexName string, obj interface{}) ([]interface{}, error)
	// IndexKeys returns the storage keys of the stored objects whose
	// set of indexed values for the named index includes the given
	// indexed value
	IndexKeys(indexName, indexedValue string) ([]string, error)
	// ListIndexFuncValues returns all the indexed values of the given index
	ListIndexFuncValues(indexName string) []string
	// ByIndex returns the stored objects whose set of indexed values
	// for the named index includes the given indexed value
	ByIndex(indexName, indexedValue string) ([]interface{}, error)
	// GetIndexer return the indexers
	GetIndexers() Indexers

	// AddIndexers adds more indexers to this store.  If you call this after you already have data
	// in the store, the results are undefined.
	AddIndexers(newIndexers Indexers) error
}

// IndexFunc knows how to compute the set of indexed values for an object.
type IndexFunc func(obj interface{}) ([]string, error)

// IndexFuncToKeyFuncAdapter adapts an indexFunc to a keyFunc.  This is only useful if your index function returns
// unique values for every object.  This conversion can create errors when more than one key is found.  You
// should prefer to make proper key and index functions.
func IndexFuncToKeyFuncAdapter(indexFunc IndexFunc) KeyFunc {
	return func(obj interface{}) (string, error) {
		indexKeys, err := indexFunc(obj)
		if err != nil {
			return "", err
		}
		if len(indexKeys) > 1 {
			return "", fmt.Errorf("too many keys: %v", indexKeys)
		}
		if len(indexKeys) == 0 {
			return "", fmt.Errorf("unexpected empty indexKeys")
		}
		return indexKeys[0], nil
	}
}

const (
	// NamespaceIndex is the lookup name for the most comment index function, which is to index by the namespace field.
	NamespaceIndex string = "namespace"
)

// MetaNamespaceIndexFunc is a default index function that indexes based on an object's namespace
func MetaNamespaceIndexFunc(obj interface{}) ([]string, error) {
	meta, err := meta.Accessor(obj)
	if err != nil {
		return []string{""}, fmt.Errorf("object has no meta: %v", err)
	}
	return []string{meta.GetNamespace()}, nil
}

// Index maps the indexed value to a set of keys in the store that match on that value
type Index map[string]sets.String

// Indexers maps a name to a IndexFunc
type Indexers map[string]IndexFunc

// Indices maps a name to an Index
type Indices map[string]Index
```
</details>

可以看到Indexer interface是在Store interface基础上增加了索引相关操作。它对应的实体为`cache`。

<details>
<summary>cache struct源码</summary>

```go
// NewIndexer returns an Indexer implemented simply with a map and a lock.
func NewIndexer(keyFunc KeyFunc, indexers Indexers) Indexer {
	return &cache{
		cacheStorage: NewThreadSafeStore(indexers, Indices{}),
		keyFunc:      keyFunc,
	}
}
```
</details>

主要方法都由cache中的`ThreadSafeStore`提供。

<details>
<summary>ThreadSafeStore interface源码</summary>

```go
// ThreadSafeStore is an interface that allows concurrent indexed
// access to a storage backend.  It is like Indexer but does not
// (necessarily) know how to extract the Store key from a given
// object.
//
// TL;DR caveats: you must not modify anything returned by Get or List as it will break
// the indexing feature in addition to not being thread safe.
//
// The guarantees of thread safety provided by List/Get are only valid if the caller
// treats returned items as read-only. For example, a pointer inserted in the store
// through `Add` will be returned as is by `Get`. Multiple clients might invoke `Get`
// on the same key and modify the pointer in a non-thread-safe way. Also note that
// modifying objects stored by the indexers (if any) will *not* automatically lead
// to a re-index. So it's not a good idea to directly modify the objects returned by
// Get/List, in general.
type ThreadSafeStore interface {
	Add(key string, obj interface{})
	Update(key string, obj interface{})
	Delete(key string)
	Get(key string) (item interface{}, exists bool)
	List() []interface{}
	ListKeys() []string
	Replace(map[string]interface{}, string)
	Index(indexName string, obj interface{}) ([]interface{}, error)
	IndexKeys(indexName, indexKey string) ([]string, error)
	ListIndexFuncValues(name string) []string
	ByIndex(indexName, indexKey string) ([]interface{}, error)
	GetIndexers() Indexers

	// AddIndexers adds more indexers to this store.  If you call this after you already have data
	// in the store, the results are undefined.
	AddIndexers(newIndexers Indexers) error
	// Resync is a no-op and is deprecated
	Resync() error
}
```
</details>

`ThreadSafeStore`需要实现的方法有：
- Add
- Update
- Delete
- Get
- List
- ListKeys
- Replace
- Index
- IndexKeys
- ListIndexFuncValues
- ByIndex
- GetIndexers

下面挑一些重要的来分析。

### Add/Update/Delete
Add/Update都是加锁操作后，调用`updateIndices`来更新索引。

<details>
<summary>Add/Update源码</summary>

```go
func (c *threadSafeMap) Add(key string, obj interface{}) {
	c.lock.Lock()
	defer c.lock.Unlock()
	oldObject := c.items[key]
	c.items[key] = obj
	c.updateIndices(oldObject, obj, key)
}

func (c *threadSafeMap) Update(key string, obj interface{}) {
	c.lock.Lock()
	defer c.lock.Unlock()
	oldObject := c.items[key]
	c.items[key] = obj
	c.updateIndices(oldObject, obj, key)
}
```
</details>

更新、删除索引部分由`updateIndices`和`deleteFromIndices`实现。

<details>
<summary>updateIndices/deleteFromIndices 源码</summary>

```go
// updateIndices modifies the objects location in the managed indexes, if this is an update, you must provide an oldObj
// updateIndices must be called from a function that already has a lock on the cache
func (c *threadSafeMap) updateIndices(oldObj interface{}, newObj interface{}, key string) {
	// if we got an old object, we need to remove it before we add it again
	if oldObj != nil {
		c.deleteFromIndices(oldObj, key)
	}
	for name, indexFunc := range c.indexers {
		indexValues, err := indexFunc(newObj)
		if err != nil {
			panic(fmt.Errorf("unable to calculate an index entry for key %q on index %q: %v", key, name, err))
		}
		index := c.indices[name]
		if index == nil {
			index = Index{}
			c.indices[name] = index
		}

		for _, indexValue := range indexValues {
			set := index[indexValue]
			if set == nil {
				set = sets.String{}
				index[indexValue] = set
			}
			set.Insert(key)
		}
	}
}

// deleteFromIndices removes the object from each of the managed indexes
// it is intended to be called from a function that already has a lock on the cache
func (c *threadSafeMap) deleteFromIndices(obj interface{}, key string) {
	for name, indexFunc := range c.indexers {
		indexValues, err := indexFunc(obj)
		if err != nil {
			panic(fmt.Errorf("unable to calculate an index entry for key %q on index %q: %v", key, name, err))
		}

		index := c.indices[name]
		if index == nil {
			continue
		}
		for _, indexValue := range indexValues {
			set := index[indexValue]
			if set != nil {
				set.Delete(key)

				// If we don't delete the set when zero, indices with high cardinality
				// short lived resources can cause memory to increase over time from
				// unused empty sets. See `kubernetes/kubernetes/issues/84959`.
				if len(set) == 0 {
					delete(index, indexValue)
				}
			}
		}
	}
}
```
</details>

至此，Indexer如何实现的我们也了然于胸。
