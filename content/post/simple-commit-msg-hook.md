---
title: "Simple Commit-Msg for Git Hook"
date: 2017-09-28T18:23:26+08:00
tags: ["git", "shell"]
---

Although I am the only contributor of my own Github project, I still want my
commit message to be tidier.

I wish all the commit messages will follow the pattern like:

    [Example]: This is an Example.
    [Exercise]: This ia an Exercise.
    [Problem]: A problem solved.
    [Other]: Maybe a merge commit.

However, I usually remember to follow this pattern after the commit, that's
really disappointed. So I decided to write a simple hook to prevent this kind of
Amnesia.

## Create `commit-msg` file
Hooks reside in the .git/hooks directory of every Git repository. And if we go
to that directory, we'll find several example hooks.

	Wenfeng-GAO.github.io git:(new-blog) ✗ ll .git/hooks
	total 80
	-rwxr-xr-x  1 Wenfeng  staff   478B May 21 09:36 applypatch-msg.sample
	-rwxr-xr-x  1 Wenfeng  staff   896B May 21 09:36 commit-msg.sample
	-rwxr-xr-x  1 Wenfeng  staff   189B May 21 09:36 post-update.sample
	-rwxr-xr-x  1 Wenfeng  staff   424B May 21 09:36 pre-applypatch.sample
	-rwxr-xr-x  1 Wenfeng  staff   1.6K May 21 09:36 pre-commit.sample
	-rwxr-xr-x  1 Wenfeng  staff   1.3K May 21 09:36 pre-push.sample
	-rwxr-xr-x  1 Wenfeng  staff   4.8K May 21 09:36 pre-rebase.sample
	-rwxr-xr-x  1 Wenfeng  staff   1.2K May 21 09:36 prepare-commit-msg.sample
	-rwxr-xr-x  1 Wenfeng  staff   3.5K May 21 09:36 update.sample

So first of all, we create a real `commit-msg` file in this directory, and make
it executable.

	cd .git/hooks
	touch commit-msg
	chmod a+x commit-msg

And here is what I did for the purpose of fixing commit message pattern.

	#!/bin/bash

	# regex to validate in commit msg
	commit_regex='\[(Example|Exercise|Problem|Other)\]:'

	RED='\033[0;31m'
	NC='\033[0m' # No Color
	error_msg="${RED}Aborting commit. Please follow the commit message pattern \
	.${NC}\n[Example|Exercise|Problem|Other]: msg"

	if ! grep -qE "$commit_regex" "$1"; then
	    echo -e "$error_msg" >&2
	    exit 1
	fi

## Test
Ok, that's done. It's not a long story :)
Now, if we are not obey the rule, we can't commit.

	algo git:(master) ✗ git commit -m "update gitignore"
	Aborting commit. Please follow the commit message pattern .
	[Example|Exercise|Problem|Other]: msg

And, if we follow the pattern, we can commit successfully.

	algo git:(master) ✗ git commit -m "[Other]: update gitignore"
	[master 967773d] [Other]: update gitignore
	 1 file changed, 4 insertions(+)

That's exactly what I want.

## References
I found two links really helpful when creating the `commit-msg` hook.

- [Documentation for Git hooks](https://git-scm.com/docs/githooks)
- [Git Hooks tutorial](https://www.atlassian.com/git/tutorials/git-hooks)

