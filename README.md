# ServerEngine

ServerEngine is a framework to implement robust multiprocess servers like Unicorn.

**Main features:**

```
                  Heartbeat via pipe
                      & auto-restart
                 /                \               ---+
+------------+  /   +----------+   \  +--------+     |
| Supervisor |------|  Server  |------| Worker |     |
+------------+      +----------+\     +--------+     | Multi-process
                        /         \                  | or multi-thread
                       /            \ +--------+     |
      Dynamic reconfiguration         | Worker |     |
     and live restart support         +--------+     |
                                                  ---+
```

ServerEngine also provides useful options and utilities such as **logging**, **signal handlers**, **changing process names** shown by `ps` command, chuser, **stacktrace** and **heap dump on signal**.

* [Examples](#examples)
  * [Simplest server](#simplest-server)
  * [Multiprocess server](#multiprocess-server)
  * [Multiprocess TCP server](#multiprocess-tcp-server)
  * [Multiprocess server on Windows and JRuby platforms](#multiprocess-server-on-windows-and-jruby-platforms)
* [Logging](#logging)
* [Supervisor auto restart](#supervisor-auto-restart)
* [Live restart](#live-restart)
* [Dynamic config reloading](#dynamic-config-reloading)
* [Signals](#signals)
* [Utilities](#utilities)
  * [BlockingFlag](#blockingflag)
  * [SocketManager](#socketmanager)
* [Module API](#module-api)
  * [Worker module](#worker-module)
  * [Server module](#server-module)
* [List of all configurations](#list-of-all-configurations)

## Examples

### Simplest server

What you need to implement at least is a worker module which has `run` and `stop` methods.

```ruby
require 'serverengine'

module MyWorker
  def run
    until @stop
      logger.info "Awesome work!"
      sleep 1
    end
  end

  def stop
    @stop = true
  end
end

se = ServerEngine.create(nil, MyWorker, {
  daemonize: true,
  log: 'myserver.log',
  pid_path: 'myserver.pid',
})
se.run
```

Send `TERM` signal (or `KILL` on Windows) to kill the daemon. See also **Signals** section bellow for details.


### Multiprocess server

Simply set **worker_type: "process"** or **worker_type: "thread"** parameter, and set number of workers to `workers` parameter.

```ruby
se = ServerEngine.create(nil, MyWorker, {
  daemonize: true,
  log: 'myserver.log',
  pid_path: 'myserver.pid',
  worker_type: 'process',
  workers: 4,
})
se.run
```

See also **Worker types** section bellow.


### Multiprocess TCP server

One of the typical implementation styles of TCP servers is that a parent process listens socket and child processes accept connections from clients.

ServerEngine allows you to optionally implement a server module to control the parent process:

```ruby
# Server module controls the parent process
module MyServer
  def before_run
    @sock = TCPServer.new(config[:bind], config[:port])
  end

  attr_reader :sock
end

# Worker module controls child processes
module MyWorker
  def run
    until @stop
      # you should use Cool.io or EventMachine actually
      c = server.sock.accept
      c.write "Awesome work!"
      c.close
    end
  end

  def stop
    @stop = true
  end
end

se = ServerEngine.create(MyServer, MyWorker, {
  daemonize: true,
  log: 'myserver.log',
  pid_path: 'myserver.pid',
  worker_type: 'process',
  workers: 4,
  bind: '0.0.0.0',
  port: 9071,
})
se.run
```


### Multiprocess server on Windows and JRuby platforms

Above **worker_type: "process"** depends on `fork` system call, which doesn't work on Windows or JRuby platform.
ServerEngine provides **worker_type: "spawn"** for those platforms. This type is not fully API compatible with the other types. You need to implement different worker module.

What you need to implement at least to use worker_type: "spawn" is `def spawn(process_manager)` method. You will call `process_manager.spawn` at the method, where `spawn` is same with `Process.spawn` excepting return value.

In addition, Windows does not support signals. ServerEngine provides **worker_process_control_type: "pipe"** for Windows (and for other platforms, if you want to use it). When using **worker_process_control_type: "pipe"**, the child process have to handle commands sent from parent process via STDIN.

You can call `Server#stop(stop_graceful)` and `Server#restart(stop_graceful)` instead of sending signals.

```ruby
module MyWorker
  def spawn(process_manager)
    env = {
      'SERVER_ENGINE_CONFIG' => config.to_json
    }
    script = %[
      require 'serverengine'
      require 'json'

      conf = JSON.parse(ENV['SERVER_ENGINE_CONFIG'], symbolize_names: true)
      logger = ServerEngine::DaemonLogger.new(conf[:log] || STDOUT, conf)

      @stop = false
      control_pipe = STDIN.dup
      STDIN.reopen(File::NULL)

      Thread.new do
        until @stop
          case control_pipe.gets.chomp
          when "GRACEFUL_STOP"
            @stop = true
          when "IMMEDIATE_STOP"
            @stop = true
          when "RELOAD"
            # do something...
          end
        end
      end

      until @stop
        logger.info 'Awesome work!'
        sleep 1
      end
    ]
    process_manager.spawn(env, "ruby", "-e", script)
  end
end

se = ServerEngine.create(nil, MyWorker, {
  worker_type: 'spawn',
  worker_process_control_type: 'pipe',
  log: 'myserver.log',
})
se.run
```


## Logging

ServerEngine logger rotates logs by 1MB and keeps 5 generations by default.

```ruby
se = ServerEngine.create(MyServer, MyWorker, {
  log: 'myserver.log',
  log_level: 'debug',
  log_rotate_age: 5,
  log_rotate_size: 1*1024*1024,
})
se.run
```

ServerEngine's default logger extends from Ruby's standard Logger library to:

* support multiprocess aware log rotation
* support reopening of log file
* support 'trace' level, which is lower level than 'debug'

See also **Configuration** section bellow.


## Supervisor auto restart

Server programs running 24x7 hours need to survive even if a process stalled because of unexpected memory swapping or network errors.

Supervisor process runs as the parent process of the server process and monitor it to restart automatically. You can enable supervisor process by setting `supervisor: true` parameter:

```ruby
se = ServerEngine.create(nil, MyWorker, {
  daemonize: true,
  pid_path: 'myserver.pid',
  supervisor: true,  # enables supervisor process
})
se.run
```


## Live restart

You can restart a server process without waiting for completion of all workers using `INT` signal (`supervisor: true` and `enable_detach: true` parameters must be enabled).
This feature allows you to minimize downtime where workers take long time to complete a task.

```
# 1. starts server
+------------+    +----------+    +-----------+
| Supervisor |----|  Server  |----| Worker(s) |
+------------+    +----------+    +-----------+

# 2. receives SIGINT and waits for shutdown of the server for server_detach_wait
+------------+    +----------+    +-----------+
| Supervisor |    |  Server  |----| Worker(s) |
+------------+    +----------+    +-----------+

# 3. starts new server if the server doesn't exit in server_detach_wait time
+------------+    +----------+    +-----------+
| Supervisor |\   |  Server  |----| Worker(s) |
+------------+ |  +----------+    +-----------+
               |
               |  +----------+    +-----------+
               \--|  Server  |----| Worker(s) |
                  +----------+    +-----------+

# 4. old server exits eventually
+------------+
| Supervisor |\
+------------+ |
               |
               |  +----------+    +-----------+
               \--|  Server  |----| Worker(s) |
                  +----------+    +-----------+
```

Note that network servers (which listen sockets) shouldn't use live restart because it causes "Address already in use" error at the server process. Instead, simply use `worker_type: "process"` configuration and send `USR1` to restart workers instead of the server. It restarts a worker without waiting for shutdown of the other workers. This way doesn't cause downtime because server process doesn't close listening sockets and keeps accepting new clients (See also `restart_server_process` parameter if necessary).


## Dynamic config reloading

Robust servers should not restart only to update configuration parameters.

```ruby
module MyWorker
  def initialize
    reload
  end

  def reload
    @message = config[:message] || "Awesome work!"
    @sleep = config[:sleep] || 1
  end

  def run
    until @stop
      logger.info @message
      sleep @sleep
    end
  end

  def stop
    @stop = true
  end
end

se = ServerEngine.create(nil, MyWorker) do
  YAML.load_file("config.yml").merge({
    daemonize: true,
    worker_type: 'process',
  })
end
se.run
```

Send `USR2` signal to reload configuration file.


## Signals

- **TERM:** graceful shutdown
- **QUIT:** immediate shutdown (available only when `worker_type` is "process")
- **USR1:** graceful restart
- **HUP:** immediate restart (available only when `worker_type` is "process")
- **USR2:** reload config file and reopen log file
- **INT:** detach process for live restarting (available only when `supervisor` and `enable_detach` parameters are true. otherwise graceful shutdown)
- **CONT:** dump stacktrace and memory information to /tmp/sigdump-<pid>.log file

Immediate shutdown and restart send SIGQUIT signal to worker processes which kills the processes.
Graceful shutdown and restart call `Worker#stop` method and wait for completion of `Worker#run` method.

Note that signals are not supported on Windows.
You have to use piped command instead of signals on Windows.
See also **Multiprocess server on Windows and JRuby platforms** section.


## Utilities

### BlockingFlag

`ServerEngine::BlockingFlag` is recommended to stop workers because `stop` method is called by a different thread from the `run` thread.

```ruby
module MyWorker
  def initialize
    @stop_flag = ServerEngine::BlockingFlag.new
  end

  def run
    until @stop_flag.wait_for_set(1.0)  # or @stop_flag.set?
      logger.info @message
    end
  end

  def stop
    @stop_flag.set!
  end
end

se = ServerEngine.create(nil, MyWorker) do
  YAML.load_file(config).merge({
    daemonize: true,
    worker_type: 'process'
  })
end
se.run
```


### SocketManager

`ServerEngine::SocketManager` is a powerful library to listen on the same port across multiple worker processes dynamically.

```ruby
module MyServer
  def before_run
    @socket_manager_path = ServerEngine::SocketManager::Server.generate_path
    @socket_manager_server = ServerEngine::SocketManager::Server.open(@socket_manager_path)
  end

  def after_run
    @socket_manager_server.close
  end

  attr_reader :socket_manager_path
end

module MyWorker
  def initialize
    @stop_flag = ServerEngine::BlockingFlag.new
    @socket_manager = ServerEngine::SocketManager::Client.new(server.socket_manager_path)
  end

  def run
    lsock = @socket_manager.listen_tcp('0.0.0.0', 12345)
    until @stop
      c = lsock.accept
      c.write "Awesome work!"
      c.close
    end
  end

  def stop
    @stop = true
  end
end

se = ServerEngine.create(MyServer, MyWorker, {
  daemonize: true,
  log: 'myserver.log',
  pid_path: 'myserver.pid',
  worker_type: 'process',
  workers: 4,
  bind: '0.0.0.0',
  port: 9071,
})
se.run
```

See also [examples](https://github.com/fluent/serverengine/tree/master/examples).


## Module API

Available methods are different depending on `worker_type`. ServerEngine supports 3 worker types:

- **embedded**: uses a thread to run worker module (default). This type doesn't support immediate shutdown or immediate restart.
- **thread**: uses threads to run worker modules. This type doesn't support immediate shutdown or immediate restart.
- **process**: uses processes to run worker modules. This type doesn't work on Windows or JRuby platform.
- **spawn**: uses processes to run worker modules. This type works on Windows and JRuby platform but available interface of worker module is limited (See also Worker module section).

### Worker module

- interface
  - `initialize` is called in the parent process (or thread) in contrast to the other methods
  - `before_fork` is called before fork for each worker process [`worker_type` = "thread", "process"]
  - `run` is the required method for `worker_type` = "embedded", "thread", "process"
  - `spawn(process_manager)` is the required method for `worker_type` = "spawn". Should call `process_manager.spawn([env,] command... [,options])`.
  - `stop` is called when TERM signal is received [`worker_type` = "embedded", "thread", "process"]
  - `reload` is called when USR2 signal is received [`worker_type` = "embedded", "thread", "process"]
  - `after_start` is called after starting the worker process in the parent process (or thread) [`worker_type` = "thread", "process", "spawn"]
- api
  - `server` server instance
  - `config` configuration
  - `logger` logger
  - `worker_id` serial id of workers beginning from 0


### Server module

- interface
  - `initialize` is called in the parent process in contrast to the other methods
  - `before_run` is called before starting workers
  - `after_run` is called before shutting down
  - `after_start` is called after starting the server process in the parent process (available if `supervisor` parameter is true)
- hook points (call `super` in these methods)
  - `reload_config`
  - `stop(stop_graceful)`
  - `restart(stop_graceful)`
- api
  - `config` configuration
  - `logger` logger


## List of all configurations

- Daemon
  - **daemonize** enables daemonize (default: false)
  - **server_cmdline** sets command-line to start the server process (e.g. `["ruby", __FILE__, "--foreground"]`). This is required on Windows and JRuby platforms because fork is not available (default: use fork).
  - **pid_path** sets the path to pid file (default: don't create pid file)
  - **supervisor** enables supervisor if it's true (default: false)
  - **daemon_process_name** changes process name ($0) of server or supervisor process
  - **chuser** changes execution user
  - **chgroup** changes execution group
  - **chumask** changes umask
  - **daemonize_error_exit_code** overrides exit code when daemonization failed because of failure of changing user, changing group, etc. (default: 1)
  - **server_process_control_type** overrides the method to send control commands to supervisor and server. Setting "pipe" here uses STDIN to receive commands (default: "signal" on UNIX, "pipe" on Windows)
  - **server_graceful_stop_signal**: overrides signal to stop the server gracefully if server_graceful_stop_signal is "signal" (default: "TERM")
  - **server_immediate_stop_signal**: overrides signal to stop the server gracefully if server_graceful_stop_signal is "signal" (default: "QUIT")
  - **server_graceful_restart_signal**: overrides signal to stop the server gracefully if server_graceful_stop_signal is "signal" (default: "USR1")
  - **server_immediate_restart_signal**: overrides signal to stop the server gracefully if server_graceful_stop_signal is "signal" (default: "HUP")
  - **server_reload_signal**: overrides signal to stop the server gracefully if server_graceful_stop_signal is "signal" (default: "USR2")
  - **server_detach_signal**: overrides signal to stop the server gracefully if server_graceful_stop_signal is "signal" (default: "INT")
  - **server_dump_signal**: overrides signal to stop the server gracefully if server_graceful_stop_signal is "signal" (default: "CONT")
- Supervisor: available only when `supervisor` parameters is true
  - **daemon_cmdline** sets command-line to start the daemon process (e.g. `["ruby", __FILE__, "--daemon"]`). This is required on Windows and JRuby platforms because fork is not available (default: use fork).
  - **server_process_name** changes process name ($0) of server process
  - **restart_server_process** restarts server process when it receives a restart command (USR1 or HUP by signal, "GRACEFUL_RESTART" or "IMMEDIATE_RESTART" through stdin pipe). (default: false)
  - **enable_detach** enables live detach (INT signal, or "DETACH" through stdin pipe) (default: true)
  - **exit_on_detach** exits supervisor after live detaching server process instead of restarting it (default: false)
  - **disable_reload** disables reload commands (USR2 signal, or "RELOAD" through stdin pipe) (default: false)
  - **server_restart_wait** sets wait time before restarting server after last restarting (default: 1.0) [dynamic reloadable]
  - **server_detach_wait** sets wait time before starting live restart (default: 10.0) [dynamic reloadable]
- Multithread server and multiprocess server: available only when `worker_type` is thread or process
  - **workers** sets number of workers (default: 1) [dynamic reloadable]
  - **start_worker_delay** sets wait time before starting a new worker (default: 0) [dynamic reloadable]
  - **start_worker_delay_rand** randomizes start_worker_delay at this ratio (default: 0.2) [dynamic reloadable]
- Multiprocess server: available only when `worker_type` is "process"
  - **worker_process_name** changes process name ($0) of workers [dynamic reloadable]
  - **worker_heartbeat_interval** sets interval of heartbeats in seconds (default: 1.0) [dynamic reloadable]
  - **worker_heartbeat_timeout** sets timeout of heartbeat in seconds (default: 180) [dynamic reloadable]
  - **worker_graceful_kill_interval** sets the first interval of TERM signals in seconds (default: 15) [dynamic reloadable]
  - **worker_graceful_kill_interval_increment** sets increment of TERM signal interval in seconds (default: 10) [dynamic reloadable]
  - **worker_graceful_kill_timeout** sets promotion timeout from TERM to QUIT signal in seconds. -1 means no timeout (default: 600) [dynamic reloadable]
  - **worker_immediate_kill_interval** sets the first interval of QUIT signals in seconds (default: 10) [dynamic reloadable]
  - **worker_immediate_kill_interval_increment** sets increment of QUIT signal interval in seconds (default: 10) [dynamic reloadable]
  - **worker_immediate_kill_timeout** sets promotion timeout from QUIT to KILL signal in seconds. -1 means no timeout (default: 600) [dynamic reloadable]
- Multiprocess spawn server: available only when `worker_type` is "spawn"
  - all parameters of multiprocess server excepting worker_process_name
  - **worker_process_control_type** sets the method to send control commands to spawned process. Set "pipe" to use pipes. Signal doesn't work on Windows (default: "signal")
  - **worker_graceful_stop_signal** sets the signal to notice graceful stop to a spawned process if worker_process_control_type is "signal" (default: "TERM")
  - **worker_immediate_stop_signal** sets the signal to notice immediate stop reload to a spawned process if worker_process_control_type is "signal" (default: "QUIT")
  - **worker_reload_signal** sets the signal to notice configuration reload to a spawned process if worker_process_control_type is "signal" (default: "USR2")
- Logger
  - **log** sets path to log file. Set "-" for STDOUT (default: STDERR) [dynamic reloadable]
  - **log_level** log level: trace, debug, info, warn, error or fatal. (default: debug) [dynamic reloadable]
  - **log_rotate_age** generations to keep rotated log files (default: 5)
  - **log_rotate_size** sets the size to rotate log files (default: 1048576)
  - **log_stdout** hooks STDOUT to log file (default: true)
  - **log_stderr** hooks STDERR to log file (default: true)
  - **logger_class** class of the logger instance (default: ServerEngine::DaemonLogger)

---

```
Author:    Sadayuki Furuhashi
Copyright: Copyright (c) 2012-2013 Sadayuki Furuhashi
License:   Apache License, Version 2.0
```

