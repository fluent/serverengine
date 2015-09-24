#
# ServerEngine
#
# Copyright (C) 2012-2013 Sadayuki Furuhashi
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#
module ServerEngine

  class MultiSpawnServer < MultiWorkerServer
    def initialize(worker_module, load_config_proc={}, &block)
      @pm = ProcessManager.new(
        auto_tick: false,
        graceful_kill_signal: Daemon::Signals::GRACEFUL_STOP,
        immediate_kill_signal: Daemon::Signals::IMMEDIATE_STOP,
        enable_heartbeat: false,
      )

      super(worker_module, load_config_proc, &block)

      @reload_signal = @config[:worker_reload_signal]
    end

    def run
      # TODO: option
      create_socket_manager

      super
    ensure
      @pm.close
    end

    def logger=(logger)
      super
      @pm.logger = logger
    end

    private

    def create_socket_manager
      sm = SocketManager::Server.new
      DRb.start_service(nil, sm)
      drb_uri = DRb.uri
      unix_socket_client = sm.new_unix_socket
      unix_socket_client.fcntl(Fcntl::F_SETFD, 0)
      @pm.drb = drb_uri
      @pm.uds = unix_socket_client
    end

    def reload_config
      super

      @pm.configure(@config, prefix: 'worker_')

      nil
    end

    def start_worker(wid)
      w = create_worker(wid)

      w.before_fork
      begin
        pmon = w.spawn(@pm)
      ensure
        w.after_start
      end

      return WorkerMonitor.new(w, wid, pmon, @reload_signal)
    end

    def wait_tick
      @pm.tick(0.5)
    end

    class WorkerMonitor < MultiProcessServer::WorkerMonitor
      def initialize(worker, wid, pmon, reload_signal)
        super(worker, wid, pmon)
        @reload_signal = reload_signal
      end

      def send_reload
        if @reload_signal
          @pmon.send_signal(@reload_signal) if @pmon
        end
        nil
      end
    end
  end

end
