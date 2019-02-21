---
title: "Python Yield Keyword"
date: 2018-02-06T18:23:56+08:00
tags: ["python"]
---

*Yield* keyword is an important feature in Python language, in order to
understand coroutine in Python, we need to understand *yield* and
*generator* first. However, this feature also makes the Python newbies like me
confused a lot, as there's no similar thing in Java or C language.

So in this post, I'll try to explain and conclude what the *yield* keyword does.

In fact, the same question was posed on
[stackoverflow](http://stackoverflow.com/questions/231767/what-does-the-yield-keyword-do), which gains 5951 votes.

### yield
>The yield expression is only used when defining a generator function, and can only be used in the body of a function definition. Using a yield expression in a function definition is sufficient to cause that definition to create a generator function instead of a normal function.

We maybe feel confused about the definition of **yield** expresion, but if we've already understood what **yield** exactly is, we may find that the qoutes from the python documentation is well expressed.

So, *the yield expression is only used when defining a generator function*.
What is a **generator function**, or first of all, what is a **gennerator**?

Generators are iterators, but you can only iterate over them once.

### Iterators
The use of iterators pervades and unifies Python. Most container objects can be looped over using a for statement:

```python
for element in [1, 2, 3]:
    print element
for element in (1, 2, 3):
    print element
for key in {'one':1, 'two':2}:
    print key
for char in "123":
    print char
for line in open("myfile.txt"):
    print line,
```

Behind the scenes, the for statement calls `iter()` on the container object. The function returns an iterator object that defines the method `next()` which accesses elements in the container one at a time. When there are no more elements, `next()` raises a `StopIteration` exception which tells the for loop to terminate. This example shows how it all works:

```python
>>> s = 'abc'
>>> it = iter(s)
>>> it
<iterator object at 0x00A1DB50>
>>> it.next()
'a'
>>> it.next()
'b'
>>> it.next()
'c'
>>> it.next()
Traceback (most recent call last):
  File "<stdin>", line 1, in ?
    it.next()
StopIteration
```
Having seen the mechanics behind the iterator protocol, it is easy to add iterator behavior to your classes. Define an `__iter__()` method which returns an object with a next() method. If the class defines `next()`, then `__iter__()` can just return self:

```python
class Reverse:
    """Iterator for looping over a sequence backwards."""
    def __init__(self, data):
        self.data = data
        self.index = len(data)

    def __iter__(self):
        return self

    def next(self):
        if self.index == 0:
            raise StopIteration
        self.index = self.index - 1
        return self.data[self.index]
```
```python
>>> rev = Reverse('spam')
>>> for char in rev:
...     print char
...
m
a
p
s
```

### Generators
Generators are iterators, but **you can only iterate over them once**. It's because they do not store all the values in memory, **they generate the values on the fly**:

Some simple generators can be coded succinctly as expressions using a syntax similar to list comprehensions but with parentheses instead of brackets.

```python
for element in (1, 2, 3):
    print element
```

```python
>>> mygenerator = (x*x for x in range(3))
>>> for i in mygenerator:
...    print(i)
0
1
4
```
It is just the same except you used `()` instead of `[]`. But, you **cannot** perform `for i in mygenerator` a second time since generators can only be used once: they calculate 0, then forget about it and calculate 1, and end calculating 4, one by one.

Generators are a simple and powerful tool for creating iterators. They are written like regular functions but use the **yield** statement whenever they want to return data.

An example shows that generators can be trivially easy to create:

```python
def reverse(data):
    for index in range(len(data)-1, -1, -1):
        yield data[index]
```

```python
>>> for char in reverse('golf'):
...     print char
...
f
l
o
g
```

With **Generators** we can deal with large scale of input in **Iterator** manner without the worry of memory limit. For example:

```python
def fib():
    a, b = 0, 1
    while True:
        yield a
        a, b = b, a+b

f = fib()
for i in xrange(1000000):
    print "%d: %d" % (i, f.next())
```

To be brief, a normal function with **yield** keyword will become a generator function, which returns a **generator** after being called. Then the **generator** could be used by calling the **generator-iterator methods** like `generator.next()`, `generator.send()`, etc.

To understand these functions, you have to read the documentation carefully, I won't discuss about it now, perhaps the last example will help you understand.

```python
def test_generator():
    i, s = 1, 2
    while True:
        j = yield(i+s)
        print i
        print j
        print s
        i += 1

>>> t = test_generator()
>>> t.next()
3
>>> t.next()
1
None
2
4
>>> t.send(2)
2
2
2
5
```

