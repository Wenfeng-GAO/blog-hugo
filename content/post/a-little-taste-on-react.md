---
title: "A Little Taste on React"
date: 2017-12-06T18:23:43+08:00
tags: ["react"]
---

I have some experience on Android development, and recently for some reason I
want to try [React Native](http://facebook.github.io/react-native/). As the RN
official tutorial said:

>So to understand the basic structure of a React Native app, you need to
understand some of the basic React concepts, like JSX, components, state, and props.

"Maybe I should listen to this guy's suggestion", I said to myself, so I
spent a week to understand what is React and how to use it.

So this article is from a front-end newbie's point of view, hope that may help
another curious newbie. :)

### What is React
[React](https://facebook.github.io/react/) is a JavaScript library for building
user interfaces.

So it's not a framework, in a traditional MVC model, it will only help you in View
part.

It enables you to have *components* as the basic block of your UI, but this have
nothing related to [Bootstrap](http://getbootstrap.com) components, you have to
write your own *components*(Of course using HTML, CSS and JavaScript).

### Why use it
So what can React do for us? Why we should learn or use it(By the way, it's
learning curve is a bit over my expectation)?

It does have good reasons:

* **Component-Based.**
Keep *component* as the basic block is really a good thing. It's much easier to
maintain and reconstruct the code, to cooperate with other developers, to separate
tasks in team, etc.

* **Declarative.**
As all HTMLs are encapsulated by JavaScript in *component*s, we can name them
meaningfully instead of `<form>` or `<div>`, etc. Declarative views make your code
more predictable and easier to read and debug.

* **Speed.**
React is fast, because instead of rendering the full web page, it will efficiently
update and render just the right components when your data changes.

### Easiest way to product
For me the easiest way to play locally and build for production is to use `npm`.
To start a project, I use `create-react-app`.

	npm install -g create-react-app
	create-react-app hello-world
	cd hello-world
	npm start

`npm start` will start a local server and serve on `http://localhost:3000`. Every
time you save your changes, it'll regenerate and refresh the web page for you,
that is really friendly to debug.

If you want to put your craft on your server, `npm run build` will help.

It generates static files in `build` directory.

	➜  tic-tac-toe git:(dev) ll build
	total 72
	-rw-r--r--  1 Wenfeng  staff   257B 12  5 23:02 asset-manifest.json
	-rw-r--r--  1 Wenfeng  staff    24K 12  5 23:02 favicon.ico
	-rw-r--r--  1 Wenfeng  staff   455B 12  5 23:02 index.html
	drwxr-xr-x  6 Wenfeng  staff   204B 12  5 23:02 static

and the only thing you have to do is to put them onto your server.

### Bonus :)
I put one of my two demos online:
[tic-tac-toe](http://demos.com.s3-website-us-east-1.amazonaws.com/tic-tac-toe/)

<iframe src="http://demos.com.s3-website-us-east-1.amazonaws.com/tic-tac-toe/" width="700" height="700">
  <p>Your browser does not support iframes.</p>
</iframe>

Source code: [Wenfeng-GAO/tic-tac-toe](https://github.com/Wenfeng-GAO/tic-tac-toe)

