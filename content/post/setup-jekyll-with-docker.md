---
title:  "Setup Jekyll in Windows environment using Docker"
date: 2016-05-12T18:20:55+08:00
tags: ["docker", "jekyll"]
---

Github provides a great service for technique bloggers: [Github
Pages](https://pages.github.com/). Just by creating a repo in GitHub, we can
host a domain like `http://username.github.io`. And with
[Jekyll](https://jekyllrb.com/) we can write blogs with Markdown and preview
blog pages locally and conveniently.

The problem for me is that my work environment is Windows, and it's not easy to
install Jekyll in Windows(especially in China). So an idea comes out with me is
to use Docker.

So let's do it!

#### Requirements
Assume that:

* Docker installed (if not go to https://www.docker.com/)
* GitHub repo for blog created

### Step One
Pull official Jekyll Docker image in your docker host machine.

        docker pull jekyll/jekyll

### Step Two
Move to your blog repo directory, for me is
`/c/Users/ewenfga/Code/github.io/Wenfeng-GAO.github.io` because docker
automatically mount with my C disk.

Run

        docker run --rm -v $(pwd):/srv/jekyll -it jekyll/jekyll bash

This line of code will run the jekyll image interatively and mount
`/srv/jekyll`directory with current directory. That's why we move to this GitHub
repo.

Run

        jekyll new . --force

This jekyll command will create all what we need for blogs, including a `_post`
directory where we place our blogs.

### Step Three
Quit the docker container(`Ctrl d`). By now we have setup our blog's structure
by jekyll, all is done and we can push to GibHub and see our blogs on the
internet if we wish.

But Jekyll also provides us a wonderful local server, by which we can preview
what we write locally.

Run

        docker run --rm --label=jekyll --volume=$(pwd):/srv/jekyll -it -p 4000:4000
jekyll/jekyll

This line of code will run a docker container as a server and export `port
4000`.

I recommand you to make an alias for this piece of code as we'll use it often.

### Step Final
Ok, now lets open our browser and type `<your-docker-host-machine-ip>:4000` in
the navigation bar, you will see something like: ![jekyll
screenshot](http://pn9ta8hbk.bkt.clouddn.com/jekyll.PNG)
Enjoy!
