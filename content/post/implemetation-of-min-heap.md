---
title: "Implemetation of Min Heap"
date: 2019-10-16T10:49:40+08:00
lastmod: 2019-10-16T10:49:40+08:00
keywords: ["heap"]
tags: ["algorithms", "heap"]
categories: ["algorithms"]
summary: "Heap is a basic and important data structure in computer science, I'll
share my simple implementation by interger slice in Go, as well as Go's native
library's implementation."
---

![heap](/post/implemetation-of-min-heap/heap.png)

# Intro
Heap is a basic and important data structure in computer science, I'll
share my simple implementation by interger slice in Go, as well as Go and Java's
native library's implementation.

# Simple implementation
```go
package heap

// Heap represents the min heap data structure of []int.
type Heap []int

// Heapify converts nums to a min heap structure in place.
func Heapify(nums []int) *Heap {
	h := Heap(nums)
	for i := len(nums)/2 - 1; i >= 0; i-- {
		siftDown(h, i)
	}
	return &h
}

// Push pushes integer v onto the heap. The complexity is O(logn) where n =
// h.Len().
func (h *Heap) Push(v int) {
	*h = append(*h, v)
	siftUp(*h, len(*h)-1)
}

// Pop removes and return the minimum value from the min heap. The complexity is
// O(logn) where n = h.Len().
func (h *Heap) Pop() int {
	ret := h.Top()
	(*h)[0] = (*h)[len(*h)-1]
	*h = (*h)[:len(*h)-1]
	siftDown(*h, 0)
	return ret
}

// Top returns the minimum value from the min heap. The complexity is O(1).
func (h *Heap) Top() int {
	if len(*h) > 0 {
		return (*h)[0]
	}
	return 0
}

// Len returns the length of heap.
func (h *Heap) Len() int {
	return len(*h)
}

func siftDown(h Heap, start int) {
	i, n := start, len(h)
	for {
		leftNode := 2*i + 1
		if leftNode >= n {
			return
		}
		j := leftNode
		if rightNode := leftNode + 1; rightNode < n && h[rightNode] < h[leftNode] {
			j = rightNode
		}
		if h[i] <= h[j] {
			return
		}
		h[i], h[j] = h[j], h[i]
		i = j
	}
}

func siftUp(h Heap, k int) {
	for k > 0 {
		parent := (k - 1) / 2
		if h[parent] > h[k] {
			h[parent], h[k] = h[k], h[parent]
		}
		k = parent
	}
}
```

# Use case
```go
package main

import (
	"fmt"
	"./heap"
)

func main() {
	data := []int{1, 3, 5, 7, 9, 2, 4, 6, 8, 10}
	h := heap.Heapify(data)
	fmt.Println(h.Pop())
	fmt.Println(h.Pop())
	fmt.Println(h.Pop())
	h.Push(5)
	h.Push(6)
	h.Push(7)
	fmt.Println(h.Pop())
	fmt.Println(h.Len())
}
```

# Go Native Library Implementation
- https://golang.org/src/container/heap/heap.go


To be continued.

# References
- [Wikipedia Heap](https://en.wikipedia.org/wiki/Heap_(data_structure))
