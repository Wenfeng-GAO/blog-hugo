---
title: "Coroutine With Gevent"
date: 2018-02-21T18:24:14+08:00
tags: ["python", "coroutine"]
---

### 背景
工作中用到gevent。

>gevent是一个基于libev的并发库。它为各种并发和网络相关的任务提供了整洁的API。

使用过程中，带着某些问题阅读了一部分源码，现在做一下总结与分享。

### 协程
Python通过`yield`与`generator`，能实现`coroutine`。举个栗子(更多更详细的例子请
参考[this awesome presentation](http://www.dabeaz.com/coroutines/Coroutines.pdf))：

```python
>>> def grep(pattern):
...     print "Looking for %s" % pattern
...     while True:
...         line = (yield)
...         if pattern in line:
...             print line
...
>>> g = grep("python")
>>> g.next()
Looking for python
>>> g.send("hello world")
>>> g.send("python generators rock!")
python generators rock!
>>>
```

原本以为gevent会是对`yield`一些封装，了解后知道，在gevent里面，上下文切换通过
yielding来完成的，但其用到的主要模式是Greenlet，
Greenlet是以C扩展模块形式接入Python的轻量级协程。Greenlet全部运行在主程序操作系统
的内部，但它们被协作式地调度。**在任何时刻，只有一个协程在运行。**

#### Greenlet
对于[Greenlet](http://greenlet.readthedocs.io/en/latest/)，暂且不多说，
通过阅读官网的API，我们知道其主要是通过`switch`这个
方法来实现跳转的，`switch`如何实现的暂不做讨论，先贴上官网的例子混个脸熟：

```python
from greenlet import greenlet

def test1():
    print 12
    gr2.switch()
    print 34

def test2():
    print 56
    gr1.switch()
    print 78

gr1 = greenlet(test1)
gr2 = greenlet(test2)
gr1.switch()
```

### 问题
使用gevent最基本的用法就是`spawn`与`joinall`了，贴一个
[官网的例子](http://www.gevent.org/intro.html#example)：

```python
>>> import gevent
>>> from gevent import socket
>>> urls = ['www.google.com', 'www.example.com', 'www.python.org']
>>> jobs = [gevent.spawn(socket.gethostbyname, url) for url in urls]
>>> gevent.joinall(jobs, timeout=2)
>>> [job.value for job in jobs]
['74.125.79.106', '208.77.188.166', '82.94.164.162']
```

主要让我困扰的是官网对于这段代码的描述:
*After the jobs have been spawned, gevent.joinall() waits for them to complete, allowing up to 2 seconds...*

感觉上是`gevent.spawn(func)`时，`func`就已经被调用，而`joinall`只是为了等待所有
`func`结束并返回结果。

然后我做了个小实验：

```python
>>> import gevent
>>> def foo():
...     print "Foo"
...
>>> def bar():
...     print "Bar"
...
>>> g = gevent.spawn(foo)
>>> g = gevent.spawn(bar)
>>> g.ready()
()
>>> gevent.joinall([g])
Foo
Bar
[<Greenlet at 0x10c2e4eb0>]
>>> g.ready()
True
>>>
# `ready()` Return a true value if and only if the greenlet has finished execution.
```

发现执行`joinall`之前，`g`一直是`not finished`的状态, `foo`, `bar`也没有输出任何
东西，直到执行了`joinall`，所以我猜测`spawn`并不会开
始执行`func`，在`joinall`时，会以协程的方式来调用`func`。
带着这个问题，去翻源码寻找答案。

### Code of gevent

`gevent/greenlet.py`

```python

    @classmethod
    def spawn(cls, *args, **kwargs):
        """
        Create a new :class:`Greenlet` object and schedule it to run ``function(*args, **kwargs)``.
        This can be used as ``gevent.spawn`` or ``Greenlet.spawn``.

        The arguments are passed to :meth:`Greenlet.__init__`.

        .. versionchanged:: 1.1b1
            If a *function* is given that is not callable, immediately raise a :exc:`TypeError`
            instead of spawning a greenlet that will raise an uncaught TypeError.
        """
        g = cls(*args, **kwargs)
        g.start()
        return g

    def start(self):
        """Schedule the greenlet to run in this loop iteration"""
        if self._start_event is None:
            self._start_event = self.parent.loop.run_callback(self.switch)
```
从这里可以看出，`spawn`主要以`func`为参数，生成了一个`Greenlet`对象，`Greenlet`
对象是`greenlet`的封装，然后执行了`start`方法。

在`start`方法中直接调用了父类`greenlet
`库中的方法，我看了半天并没有理出头绪，线索中断了。于是去看`joinall`碰碰运气。

`gevent/greenlet.py`

```python

def joinall(greenlets, timeout=None, raise_error=False, count=None):
    """
    Wait for the ``greenlets`` to finish.

    :param greenlets: A sequence (supporting :func:`len`) of greenlets to wait for.
    :keyword float timeout: If given, the maximum number of seconds to wait.
    :return: A sequence of the greenlets that finished before the timeout (if any)
        expired.
    """
    if not raise_error:
        return wait(greenlets, timeout=timeout, count=count)

    done = []
    for obj in iwait(greenlets, timeout=timeout, count=count):
        if getattr(obj, 'exception', None) is not None:
            if hasattr(obj, '_raise_exception'):
                obj._raise_exception()
            else:
                raise obj.exception
        done.append(obj)
    return done
```

`hub.py`

```python
def wait(objects=None, timeout=None, count=None):
    """
    Wait for ``objects`` to become ready or for event loop to finish.

    If ``objects`` is provided, it must be a list containing objects
    implementing the wait protocol (rawlink() and unlink() methods):

    - :class:`gevent.Greenlet` instance
    - :class:`gevent.event.Event` instance
    - :class:`gevent.lock.Semaphore` instance
    - :class:`gevent.subprocess.Popen` instance

    If ``objects`` is ``None`` (the default), ``wait()`` blocks until
    the current event loop has nothing to do (or until ``timeout`` passes):

    - all greenlets have finished
    - all servers were stopped
    - all event loop watchers were stopped.

    If ``count`` is ``None`` (the default), wait for all ``objects``
    to become ready.

    If ``count`` is a number, wait for (up to) ``count`` objects to become
    ready. (For example, if count is ``1`` then the function exits
    when any object in the list is ready).

    If ``timeout`` is provided, it specifies the maximum number of
    seconds ``wait()`` will block.

    Returns the list of ready objects, in the order in which they were
    ready.

    .. seealso:: :func:`iwait`
    """
    if objects is None:
        return get_hub().join(timeout=timeout)
    return list(iwait(objects, timeout, count))
```

`hub.py`

```python
def iwait(objects, timeout=None, count=None):
    """
    Iteratively yield *objects* as they are ready, until all (or *count*) are ready
    or *timeout* expired.

    :param objects: A sequence (supporting :func:`len`) containing objects
        implementing the wait protocol (rawlink() and unlink()).
    :keyword int count: If not `None`, then a number specifying the maximum number
        of objects to wait for. If ``None`` (the default), all objects
        are waited for.
    :keyword float timeout: If given, specifies a maximum number of seconds
        to wait. If the timeout expires before the desired waited-for objects
        are available, then this method returns immediately.

    .. seealso:: :func:`wait`

    .. versionchanged:: 1.1a1
       Add the *count* parameter.
    .. versionchanged:: 1.1a2
       No longer raise :exc:`LoopExit` if our caller switches greenlets
       in between items yielded by this function.
    """
    # QQQ would be nice to support iterable here that can be generated slowly (why?)
    if objects is None:
        yield get_hub().join(timeout=timeout)
        return

    count = len(objects) if count is None else min(count, len(objects))
    waiter = _MultipleWaiter()
    switch = waiter.switch

    if timeout is not None:
        timer = get_hub().loop.timer(timeout, priority=-1)
        timer.start(switch, _NONE)

    try:
        for obj in objects:
            obj.rawlink(switch)

        for _ in xrange(count):
            item = waiter.get()
            waiter.clear()
            if item is _NONE:
                return
            yield item
    finally:
        if timeout is not None:
            timer.stop()
        for aobj in objects:
            unlink = getattr(aobj, 'unlink', None)
            if unlink:
                try:
                    unlink(switch)
                except: # pylint:disable=bare-except
                    traceback.print_exc()
```

看到这里，终于看到了希望。
`Waiter`是对`greenlet`的`switch`, `throw`等方法一个wrapper, 而它的`switch`方法
主要也是为了调用`greenlet`的`switch`方法。

`hub.py`

```python
    def switch(self, value=None):
        """Switch to the greenlet if one's available. Otherwise store the value."""
        greenlet = self.greenlet
        if greenlet is None:
            self.value = value
            self._exception = None
        else:
            assert getcurrent() is self.hub, "Can only use Waiter.switch method from the Hub greenlet"
            switch = greenlet.switch
            try:
                switch(value)
            except: # pylint:disable=bare-except
                self.hub.handle_error(switch, *sys.exc_info())
```

而`greenlet`的`switch`是做什么的自然就不用多说了。

当然，方法的调用过程中还有一些`callback`的用法，篇幅有限，就不讨论那么详细了。

### 结论
在`gevent.joinall()`方法中，我们看到了协程，看到了方法是如何被实现调用与跳转的。
`gevent.spawn()`将方法包装成了`Greenlet`对象，放到了队列之中，或许有进一步的触发，
这里我并没有挖掘到太多，便不多言。

