---
title: "Basic Shell Commands"
date: 2017-07-29T18:23:09+08:00
tags: ["shell"]
---

公司某个产品的测试环境比较复杂，它需要在 *OpenStack* 上创建3个节点，其中2个节点安装产品并实现高可用(HA)，第3个节点（TestAgent节点）与产品节点通过接收与发送数据包进行测试。

整个部署与测试流程都需要用Jenkins做自动化测试，而我的任务是将TestAgent节点移植到Docker容器中。用时一个多月，从熟悉源代码的部署与测试流程，到OpenStack的UI界面和CLI命令的基本使用，到OpenStack网络通信的基本理解，到Python的学习与使用(如使用pexpect通过ssh执行shell命令和脚本)， 到shell脚本的熟悉与使用，这个过程中爬过了许多大大小小的坑，也收获了很多东西，这里主要总结一下shell脚本的常用命令。

## if
`if TEST-COMMANDS; then CONSEQUENT-COMMANDS; fi`

其中`TEST-COMMANDS`一般有3种情形：

- `shell command`
  如果它的返回状态为0，则执行`CONSEQUENT-COMMANDS`
- bracket `[]`
- double bracket `[[]]`
  在方括号内都会做一些判断，如判断文件是否存在，`[ -f FILE ]`等等，而其两者的区别在于`[[]]`是`[]`的拓展，只支持与bash、zsh等几种shell，所以可移植性要差一些，不过如果不考虑移植性的问题，`[[]]`会更加简洁与可读，具体可以参考 [StackOverFlow上的回答](http://stackoverflow.com/questions/669452/is-preferable-over-in-bash-scripts)以及[这篇文档](http://mywiki.wooledge.org/BashFAQ/031)。

有时简单的逻辑关系可以直接使用`&&`代替。

## grep

`grep -rl “pattern” file` 返回含有“pattern”的文件名，`grep`常与`awk`或者`cut`一起使用，例如

- `grep "foo" file.txt | awk '{print $1}'`
- `grep "/bin/bash" /etc/passwd | cut -d':' -f1,6`

## sed

- `sed -i 'pattern' file` 直接操作文件的内容而不是stdout
- `sed 's/hello/bonjour/' greetings.txt` 基本用法
- `sed  '/is beautiful/i Life' input` 在之前插入一行
- `sed  '/Hello/a World' input` 在之后增加一行
- `sed '/^\s*$/d'` 删除空白行

## echo with color

- `RED='\033[0;31m'`
- `NC='\033[0m' # No Color`
- `echo -e "I ${RED}love${NC} Stack Overflow\n"`

