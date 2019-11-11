---
title: "Java Attach Mechanism"
date: 2019-11-11T15:26:07+08:00
lastmod: 2019-11-11T15:26:07+08:00
keywords: ["java", "attach"]
tags: ["java"]
categories: []
summary: "Today, we’ll uncover the mystery of an important mechanism provided by JVM: Attach Mechanism, 
which is used to enable communication between processes in and out of JVM."
---

We often use tools like *JStack* to dump threads of our java programs, or use
profiling tools like *Async-Profiler* to profile java processes. You may
wonder how these tools work, or specifically how these tools communicate with
target Java processes.

Today, we'll uncover the mystery and talk about an important mechanism provided
by JVM: **Attach
Mechanism**, which is used to enable communication between processes in and out
of JVM.

## What is Java attach
When we use *JStack* to dump out threads, we may find `Attach Listener` and `Signal Dispatcher`, these 2 threads are the key threads we'll talk about today.

```bash
# jstack output snippets...

"Attach Listener" #39054 daemon prio=9 os_prio=0 tid=0x00007f2aa8002000 nid=0x15188 waiting on condition [0x0000000000000000]
   java.lang.Thread.State: RUNNABLE

"Signal Dispatcher" #5 daemon prio=9 os_prio=0 tid=0x00007f2ae021f000 nid=0x51 runnable [0x0000000000000000]
   java.lang.Thread.State: RUNNABLE

"Surrogate Locker Thread (Concurrent GC)" #4 daemon prio=9 os_prio=0 tid=0x00007f2ae021d800 nid=0x50 waiting on condition [0x0000000000000000]
   java.lang.Thread.State: RUNNABLE

"Finalizer" #3 daemon prio=8 os_prio=0 tid=0x00007f2ae01ea800 nid=0x4f in Object.wait() [0x00007f2ad0099000]
   java.lang.Thread.State: WAITING (on object monitor)
	at java.lang.Object.wait(Native Method)
	at java.lang.ref.ReferenceQueue.remove(ReferenceQueue.java:144)
	- locked <0x00000000d7974750> (a java.lang.ref.ReferenceQueue$Lock)
	at java.lang.ref.ReferenceQueue.remove(ReferenceQueue.java:165)
	at java.lang.ref.Finalizer$FinalizerThread.run(Finalizer.java:216)

"main" #1 prio=5 os_prio=0 tid=0x00007f2ae000c000 nid=0x47 runnable [0x00007f2ae787f000]
   java.lang.Thread.State: RUNNABLE
	at java.net.PlainSocketImpl.socketAccept(Native Method)
	at java.net.AbstractPlainSocketImpl.accept(AbstractPlainSocketImpl.java:409)
	at java.net.ServerSocket.implAccept(ServerSocket.java:545)
	...
```
Through *Java Attach Mechanism*, we could launch a process to communicate with
target Java process, to let it dump threads, dump heaps, print flags or many
other options. Registered functions that JVM supported after attaching are as
following.
```cpp
static AttachOperationFunctionInfo funcs[] = {
  { "agentProperties",  get_agent_properties },
  { "datadump",         data_dump },
  { "dumpheap",         dump_heap },
  { "load",             load_agent },
  { "properties",       get_system_properties },
  { "threaddump",       thread_dump },
  { "inspectheap",      heap_inspection },
  { "setflag",          set_flag },
  { "printflag",        print_flag },
  { "jcmd",             jcmd },
  { NULL,               NULL }
};
```
## How does attach work
Basically, there're only a few fixed method to enable IPC(inter-process
communication) in linux, such as *Pipe*, *Shared Memory*, *Unix Domain Socket*,
etc, here JVM implementation uses **UDS(Unix Domain Socket)**.

So there have to be a UDS server launched by JVM, which listens a socket. In
fact, **Attach Listener** thread is responsible for this job, as showed in the
thread-dump output before.
```bash
"Attach Listener" #39054 daemon prio=9 os_prio=0 tid=0x00007f2aa8002000 nid=0x15188 waiting on condition [0x0000000000000000]
   java.lang.Thread.State: RUNNABLE
```

However, **Attach Listener** thread may not exist when JVM starts, which means
JVM won't start an UDS server as soon as it starts. It won't launch the server
until a `SIGQUIT` signal is recieved, which indicates an UDS server is needed.

And that's why a **Signal Dispatcher** thread is created as soon as JVM starts, which can also
be found in the thread-dump output before.
```bash
"Signal Dispatcher" #5 daemon prio=9 os_prio=0 tid=0x00007f2ae021f000 nid=0x51 runnable [0x0000000000000000]
   java.lang.Thread.State: RUNNABLE
```

After UDS server being ready, JVM could communicate with other process in some
simple protocol. Let's see some details in the source code.

## Source code walk through
### How does "Attach Listener" thread start
JVM will start **Signal Dispatcher** thread to listen and handle
`SIGBREAK(SIGQUIT)` signal.
```cpp
// runtime/os.cpp
void os::initialize_jdk_signal_support(TRAPS) {
  if (!ReduceSignalUsage) {
    // Setup JavaThread for processing signals
    const char thread_name[] = "Signal Dispatcher";
    Handle string = java_lang_String::create_from_str(thread_name, CHECK);

    ...

    { MutexLocker mu(Threads_lock);
      JavaThread* signal_thread = new JavaThread(&signal_thread_entry);

      ...
      Threads::add(signal_thread);
      Thread::start(signal_thread);
    }
    // Handle ^BREAK
    os::signal(SIGBREAK, os::user_handler());
  }
}
```
`signal_thread_entry` function handles the main logic.
```cpp
static void signal_thread_entry(JavaThread* thread, TRAPS) {
  os::set_priority(thread, NearMaxPriority);
  while (true) {
    int sig;
    {
      // FIXME : Currently we have not decided what should be the status
      //         for this java thread blocked here. Once we decide about
      //         that we should fix this.
      sig = os::signal_wait();
    }
    if (sig == os::sigexitnum_pd()) {
       // Terminate the signal thread
       return;
    }

    switch (sig) {
      case SIGBREAK: {
#if INCLUDE_SERVICES
        // Check if the signal is a trigger to start the Attach Listener - in that
        // case don't print stack traces.
        if (!DisableAttachMechanism) {
          // Attempt to transit state to AL_INITIALIZING.
          AttachListenerState cur_state = AttachListener::transit_state(AL_INITIALIZING, AL_NOT_INITIALIZED);
          if (cur_state == AL_INITIALIZING) {
            // Attach Listener has been started to initialize. Ignore this signal.
            continue;
          } else if (cur_state == AL_NOT_INITIALIZED) {
            // Start to initialize.
            if (AttachListener::is_init_trigger()) {
              // Attach Listener has been initialized.
              // Accept subsequent request.
              continue;
            } else {
              // Attach Listener could not be started.
              // So we need to transit the state to AL_NOT_INITIALIZED.
              AttachListener::set_state(AL_NOT_INITIALIZED);
            }
          } else if (AttachListener::check_socket_file()) {
            // Attach Listener has been started, but unix domain socket file
            // does not exist. So restart Attach Listener.
            continue;
          }
        }
#endif
        // Print stack traces
        // Any SIGBREAK operations added here should make sure to flush
        // the output stream (e.g. tty->flush()) after output.  See 4803766.
        // Each module also prints an extra carriage return after its output.
        ...
    }
  }
}
```
Core algorithms in this function:

1. use `os::signal_wait` to wait signals
2. Once `SIGQUIT(SIGBREAK)` signal recieved, `Attach Listener` may be triggered
(check if **attach mechanism** is opened, can be controlled by JVM argument `-XX:+|-DisableAttachMechanism`)
3. function `AttachListener::is_init_trigger()` is called when `cur_state == AL_NOT_INITIALIZED`
    ```cpp
    // If the file .attach_pid<pid> exists in the working directory
    // or /tmp then this is the trigger to start the attach mechanism
    bool AttachListener::is_init_trigger() {
      if (init_at_startup() || is_initialized()) {
        return false;               // initialized at startup or already initialized
      }
      char fn[PATH_MAX + 1];
      int ret;
      struct stat64 st;
      sprintf(fn, ".attach_pid%d", os::current_process_id());
      RESTARTABLE(::stat64(fn, &st), ret);
      if (ret == -1) {
        log_trace(attach)("Failed to find attach file: %s, trying alternate", fn);
        snprintf(fn, sizeof(fn), "%s/.attach_pid%d",
                 os::get_temp_directory(), os::current_process_id());
        RESTARTABLE(::stat64(fn, &st), ret);
        if (ret == -1) {
          log_debug(attach)("Failed to find attach file: %s", fn);
        }
      }
      if (ret == 0) {
        // simple check to avoid starting the attach mechanism when
        // a bogus non-root user creates the file
        if (os::Posix::matches_effective_uid_or_root(st.st_uid)) {
          init();
          log_trace(attach)("Attach triggered by %s", fn);
          return true;
        } else {
          log_debug(attach)("File %s has wrong user id %d (vs %d). Attach is not triggered", fn, st.st_uid, geteuid());
        }
      }
      return false;
    }
    ```
    In this function, `init` function will be called if file `.Attach_pid<PID>`
    exists and `uid` of this file is correct.
4. **Attach Listener** thread will be created and started in `init` function
    ```cpp
    // services/attachListener.cpp
    // Starts the Attach Listener thread
    void AttachListener::init() {
      EXCEPTION_MARK;

      const char thread_name[] = "Attach Listener";
      Handle string = java_lang_String::create_from_str(thread_name, THREAD);
      if (has_init_error(THREAD)) {
        set_state(AL_NOT_INITIALIZED);
        return;
      }

      // Initialize thread_oop to put it into the system threadGroup
      Handle thread_group (THREAD, Universe::system_thread_group());
      Handle thread_oop = JavaCalls::construct_new_instance(SystemDictionary::Thread_klass(),
                           vmSymbols::threadgroup_string_void_signature(),
                           thread_group,
                           string,
                           THREAD);
      if (has_init_error(THREAD)) {
        set_state(AL_NOT_INITIALIZED);
        return;
      }

     ...

      { MutexLocker mu(Threads_lock);
        JavaThread* listener_thread = new JavaThread(&attach_listener_thread_entry);

        // Check that thread and osthread were created
        if (listener_thread == NULL || listener_thread->osthread() == NULL) {
          vm_exit_during_initialization("java.lang.OutOfMemoryError",
                                        os::native_thread_creation_failed_msg());
        }

        java_lang_Thread::set_thread(thread_oop(), listener_thread);
        java_lang_Thread::set_daemon(thread_oop());

        listener_thread->set_threadObj(thread_oop());
        Threads::add(listener_thread);
        Thread::start(listener_thread);
      }
    }
    ```
### What will "Attach Listener" thread do
We can see `attach_listener_thread_entry` function is referred when create
**Attach Listener** thread, let's see what will it do.
```cpp
// The Attach Listener threads services a queue. It dequeues an operation
// from the queue, examines the operation name (command), and dispatches
// to the corresponding function to perform the operation.

static void attach_listener_thread_entry(JavaThread* thread, TRAPS) {
  os::set_priority(thread, NearMaxPriority);

  assert(thread == Thread::current(), "Must be");
  assert(thread->stack_base() != NULL && thread->stack_size() > 0,
         "Should already be setup");

  if (AttachListener::pd_init() != 0) {
    AttachListener::set_state(AL_NOT_INITIALIZED);
    return;
  }
  AttachListener::set_initialized();

  for (;;) {
    AttachOperation* op = AttachListener::dequeue();
    if (op == NULL) {
      AttachListener::set_state(AL_NOT_INITIALIZED);
      return;   // dequeue failed or shutdown
    }

    ResourceMark rm;
    bufferedStream st;
    jint res = JNI_OK;

    // handle special detachall operation
    if (strcmp(op->name(), AttachOperation::detachall_operation_name()) == 0) {
      AttachListener::detachall();
    } else if (!EnableDynamicAgentLoading && strcmp(op->name(), "load") == 0) {
      st.print("Dynamic agent loading is not enabled. "
               "Use -XX:+EnableDynamicAgentLoading to launch target VM.");
      res = JNI_ERR;
    } else {
      // find the function to dispatch too
      AttachOperationFunctionInfo* info = NULL;
      for (int i=0; funcs[i].name != NULL; i++) {
        const char* name = funcs[i].name;
        assert(strlen(name) <= AttachOperation::name_length_max, "operation <= name_length_max");
        if (strcmp(op->name(), name) == 0) {
          info = &(funcs[i]);
          break;
        }
      }

      // check for platform dependent attach operation
      if (info == NULL) {
        info = AttachListener::pd_find_operation(op->name());
      }

      if (info != NULL) {
        // dispatch to the function that implements this operation
        res = (info->func)(op, &st);
      } else {
        st.print("Operation %s not recognized!", op->name());
        res = JNI_ERR;
      }
    }

    // operation complete - send result and output to client
    op->complete(res, &st);
  }

  ShouldNotReachHere();
}
```
In this function, sevaral things will be done:

1. `pd_init` function will be called, which will call `LinuxAttachListener::init()`
function to create a stream socket and bind to file `/tmp/.java_pid<PID>`, and
start to `listen`
    ```cpp
    // os/linux/attachListener_linux.cpp
    int LinuxAttachListener::init() {
      char path[UNIX_PATH_MAX];          // socket file
      char initial_path[UNIX_PATH_MAX];  // socket file during setup
      int listener;                      // listener socket (file descriptor)

      // register function to cleanup
      if (!_atexit_registered) {
        _atexit_registered = true;
        ::atexit(listener_cleanup);
      }

      int n = snprintf(path, UNIX_PATH_MAX, "%s/.java_pid%d",
                       os::get_temp_directory(), os::current_process_id());
      if (n < (int)UNIX_PATH_MAX) {
        n = snprintf(initial_path, UNIX_PATH_MAX, "%s.tmp", path);
      }
      if (n >= (int)UNIX_PATH_MAX) {
        return -1;
      }

      // create the listener socket
      listener = ::socket(PF_UNIX, SOCK_STREAM, 0);
      if (listener == -1) {
        return -1;
      }

      // bind socket
      struct sockaddr_un addr;
      memset((void *)&addr, 0, sizeof(addr));
      addr.sun_family = AF_UNIX;
      strcpy(addr.sun_path, initial_path);
      ::unlink(initial_path);
      int res = ::bind(listener, (struct sockaddr*)&addr, sizeof(addr));
      if (res == -1) {
        ::close(listener);
        return -1;
      }

      // put in listen mode, set permissions, and rename into place
      res = ::listen(listener, 5);
      if (res == 0) {
        RESTARTABLE(::chmod(initial_path, S_IREAD|S_IWRITE), res);
        if (res == 0) {
          // make sure the file is owned by the effective user and effective group
          // e.g. the group could be inherited from the directory in case the s bit is set
          RESTARTABLE(::chown(initial_path, geteuid(), getegid()), res);
          if (res == 0) {
            res = ::rename(initial_path, path);
          }
        }
      }
      if (res == -1) {
        ::close(listener);
        ::unlink(initial_path);
        return -1;
      }
      set_path(path);
      set_listener(listener);

      return 0;
    }
    ```
2. If succeeded, call `AttachListener::set_initialized()` function to set state
   to `AL_INITIALIZED`
3. In non-stopping loop, keep dequeuing `option`s by `LinuxAttachListener::dequeue()`
   function, then call the function belongs to the dequeued `option`; the subscribed
   functions are:
   ```cpp
   static AttachOperationFunctionInfo funcs[] = {
      { "agentProperties",  get_agent_properties },
      { "datadump",         data_dump },
      { "dumpheap",         dump_heap },
      { "load",             load_agent },
      { "properties",       get_system_properties },
      { "threaddump",       thread_dump },
      { "inspectheap",      heap_inspection },
      { "setflag",          set_flag },
      { "printflag",        print_flag },
      { "jcmd",             jcmd },
      { NULL,               NULL }
    };
   ```
### IPC protocal during communication
Finally, let's have a look at the protocal during IPC communication, which lies
in the `dequeue` process we talked before.

`LinuxAttachListener::dequeue()` function will be called in the `dequeue`
process.
```cpp
// os/linux/attachListener_linux.cpp
// Dequeue an operation
//
// In the Linux implementation there is only a single operation and clients
// cannot queue commands (except at the socket level).
//
LinuxAttachOperation* LinuxAttachListener::dequeue() {
  for (;;) {
    int s;

    // wait for client to connect
    struct sockaddr addr;
    socklen_t len = sizeof(addr);
    RESTARTABLE(::accept(listener(), &addr, &len), s);
    if (s == -1) {
      return NULL;      // log a warning?
    }

    // get the credentials of the peer and check the effective uid/guid
    struct ucred cred_info;
    socklen_t optlen = sizeof(cred_info);
    if (::getsockopt(s, SOL_SOCKET, SO_PEERCRED, (void*)&cred_info, &optlen) == -1) {
      log_debug(attach)("Failed to get socket option SO_PEERCRED");
      ::close(s);
      continue;
    }

    if (!os::Posix::matches_effective_uid_and_gid_or_root(cred_info.uid, cred_info.gid)) {
      log_debug(attach)("euid/egid check failed (%d/%d vs %d/%d)",
              cred_info.uid, cred_info.gid, geteuid(), getegid());
      ::close(s);
      continue;
    }

    // peer credential look okay so we read the request
    LinuxAttachOperation* op = read_request(s);
    if (op == NULL) {
      ::close(s);
      continue;
    } else {
      return op;
    }
  }
}
```
We can find the protocal part in `LinuxAttachListener::read_request` function.
```cpp
// os/linux/attachListener_linux.cpp
LinuxAttachOperation* LinuxAttachListener::read_request(int s) {
  char ver_str[8];
  sprintf(ver_str, "%d", ATTACH_PROTOCOL_VER);

  // The request is a sequence of strings so we first figure out the
  // expected count and the maximum possible length of the request.
  // The request is:
  //   <ver>0<cmd>0<arg>0<arg>0<arg>0
  // where <ver> is the protocol version (1), <cmd> is the command
  // name ("load", "datadump", ...), and <arg> is an argument
  int expected_str_count = 2 + AttachOperation::arg_count_max;
  const int max_len = (sizeof(ver_str) + 1) + (AttachOperation::name_length_max + 1) +
    AttachOperation::arg_count_max*(AttachOperation::arg_length_max + 1);

  char buf[max_len];
  int str_count = 0;

  ...
}
```

## Conclusion
That's the entire interactive process of the **Java Attach Mechanism**. After
walking through the source code, we have a better understanding of this
mechanism, which is widely used by many tools like *JStack*, *JPS*,
*Async-Profiler*, etc.

We can see the core method to enable **Attach** is **Unix Domain Socket**, JVM
subcribes some basic functions, and through a declaired protocal, some other
process may *call* these functions to dump threads, dump heaps, etc.

In addition, rather than launch the socket server on starting, JVM decide to
launch the server when several requirements satisfied, including `SIGQUIT`
signal recieved, `.Attach_pid<PID>` file found, etc.

## References
- http://lovestblog.cn/blog/2014/06/18/jvm-attach/
