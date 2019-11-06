---
title: "New() vs Make()"
date: 2019-11-05T21:24:24+08:00
lastmod: 2019-11-05T21:24:24+08:00
keywords: ["go"]
tags: ["go"]
categories: ["go"]
summary: "This blog will briefly describe the differences between the built-in
`new()` and `make()` functions in Go."
---

Go has two allocation primitives, the built-in functions `new` and `make`.

## new
The built-in `new(T)` function returns a pointer to a newly allocated zero value of type `T`.
For example, there're 3 different ways to create a pointer `p` that points to a
zeroed `bytes.Buffer` value, each of which are equivalent:

```go
// Allocate enough memory to store a bytes.Buffer value
// and return a pointer to the value's address.
var buf bytes.Buffer
p := &buf

// Use a composite literal to perform allocation and
// return a pointer to the value's address.
p := &bytes.Buffer{}

// Use the new function to perform allocation, which will
// return a pointer to the value's address.
p := new(bytes.Buffer)
```
Some document in go source libray.
```go
// https://golang.org/src/builtin/builtin.go?s=7789:7809#L184
// The new built-in function allocates memory. The first argument is a type,
// not a value, and the value returned is a pointer to a newly
// allocated zero value of that type.
func new(Type) *Type
```

## make
The built-in `make(T, args)` applies only to **maps**, **slices** and **channels**, it returns an
*initialized*(not *zeroed*) value of type `T`(not `*T`).

Some document in go source libray.
```go
// https://golang.org/src/builtin/builtin.go?s=7566:7609#L179
// The make built-in function allocates and initializes an object of type
// slice, map, or chan (only). Like new, the first argument is a type, not a
// value. Unlike new, make's return type is the same as the type of its
// argument, not a pointer to it. The specification of the result depends on
// the type:
//	Slice: The size specifies the length. The capacity of the slice is
//	equal to its length. A second integer argument may be provided to
//	specify a different capacity; it must be no smaller than the
//	length. For example, make([]int, 0, 10) allocates an underlying array
//	of size 10 and returns a slice of length 0 and capacity 10 that is
//	backed by this underlying array.
//	Map: An empty map is allocated with enough space to hold the
//	specified number of elements. The size may be omitted, in which case
//	a small starting size is allocated.
//	Channel: The channel's buffer is initialized with the specified
//	buffer capacity. If zero, or the size is omitted, the channel is
//	unbuffered.
func make(t Type, size ...IntegerType) Type
```

Of course we can `new` a **slice**, **map** or **channel**, but it rarely has
any sense.
```go
s := new([]string)
fmt.Println(len(*s))  // 0
fmt.Println(*s == nil) // true

m := new(map[string]int)
fmt.Println(m == nil) // false
fmt.Println(*m == nil) // true

c := new(chan int)
fmt.Println(c == nil) // false
fmt.Println(*c == nil) // true
```

## Conclusion
In short, `new(T)` returns address of zeroed allocation of type `T`, `make()`
only works for **slice**, **map** and **channel** and returns value instead of
pointer.

## References
- https://www.godesignpatterns.com/2014/04/new-vs-make.html
- https://dave.cheney.net/2014/08/17/go-has-both-make-and-new-functions-what-gives
