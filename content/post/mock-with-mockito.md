---
title: "Mock With Mockito"
date: 2016-05-13T18:21:19+08:00
tags: ["unit-test"]
---

Unit test takes an important role in software development, which ensures the code quality.
[Mockito](http://mockito.org/) is an open-source mocking framework for unit tests in Java.
After trying, I found it very nice and easy to use, so this blog aims to introducing Mockito
to you.
### Why mock?
Mock means using a *fake* thing instead of the original one to help us test, but why do we
need that?

Martin Fowler's article [Mocks Aren't Stubs](http://martinfowler.com/articles/mocksArentStubs.html)
makes a lot sense explainning why.

##### Different test/thinking styles
The classic test case uses a **state verification style**, which means:
for exampel, if all goes well our SUT(subject under test) will call another Object's method
(`AnotherObject.method()` for example), so we'll run our SUT and test whether `AnotherObject.method()`
returns the expected value. If it does returns the expected value, the test passes.

That is the classic and traditional *state verification style*. But we can alse choose a different
test style, we call it **behavior verification style**.
We know that our SUT passes if it calls `AnotherObject.method()`, and whether `AnotherObject.method()`
returns expected values or not is not our responsibility and we don't care about it! So the idea is
to *verify* whether the `AnotherObject.method()` is called or not.

##### Isolated and clean code
The second reason we need to **mock** is more fundamental. Usually `AnotherObject.method()` is not that
easy to run, perhaps it depends tough environment like internet connection, database connection ,etc.
So instead of really calling the method, we call our mocked method and just *verify* the call or verify its *stubbed*
return values, all is done.

### Use Mockito
Mockito is very easy to use.

You can mock and verify the interactions like

```java
import static org.mockito.Mockito.*;

// mock creation
List mockedList = mock(List.class);

// using mock object - it does not throw any "unexpected interaction" exception
mockedList.add("one");
mockedList.clear();

// selective, explicit, highly readable verification
verify(mockedList).add("one");
verify(mockedList).clear();
```

And stub method calls

```java
// you can mock concrete classes, not only interfaces
LinkedList mockedList = mock(LinkedList.class);

// stubbing appears before the actual execution
when(mockedList.get(0)).thenReturn("first");

// the following prints "first"
System.out.println(mockedList.get(0));

// the following prints "null" because get(999) was not stubbed
System.out.println(mockedList.get(999));
```

### How can Mockito mock an object
Mockito can mock whatever objects you own, I'm curious about how it works, and after going through
some source code, it's much clearer to me.

Here's the flow of its calls.
![Mockito Mock Flow](http://pn9ta8hbk.bkt.clouddn.com/mockito.png)

The fundamental parts are `generateMockClass(MockFeatures<T>)` and `newInstance(Class<T>)` methods.
`generateMockClass` method uses a third-part library [ByteBuddy](http://bytebuddy.net/#/) to generate
class.

Byte Buddy is a code generation library for creating Java classes during the runtime of a Java
application and without the help of a compiler.
To generate a class is just like:

```java
Class<?> dynamicType = new ByteBuddy()
  .subclass(Object.class)
  .method(ElementMatchers.named("toString"))
  .intercept(FixedValue.value("Hello World!"))
  .make()
  .load(getClass().getClassLoader(), ClassLoadingStrategy.Default.WRAPPER)
  .getLoaded();
```
The class we get is the child class of the class we want to mock(T).

Then in the `newInstance` method, Mockito uses another third-part libray [Objenesis](http://objenesis.org/) to
initiate a new object of the class we get from `generateMockClass`.

Why Mockito uses a libray to initaite object rather than initaite it directly? Because the class we get extends
the realy class we want to mock, if we `new` it directly, the real class will be newed, which conflicts the
purpose of using Mock. Instead, by using *Objenesis*, only the child class will be newed.

So now the mock object has been created, and through the process we understand why Mockito can't mock private
or static method(because the child class can't extends parent's private/static methods).
