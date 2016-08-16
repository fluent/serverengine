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

require 'serverengine/utils'
require 'serverengine/signals'
require 'serverengine/privilege'

require 'serverengine/monitor'

require 'serverengine/process_manager'
require 'serverengine/multi_worker_server'

module ServerEngine
  class MultiProcessServer < MultiWorkerServer
    def initialize(worker_module, load_config_proc={}, &block)
      @pm = ProcessManager.new(
        auto_tick: false,
        graceful_kill_signal: Signals::GRACEFUL_STOP,
        immediate_kill_signal: Signals::IMMEDIATE_STOP,
        enable_heartbeat: true,
        auto_heartbeat: true,
        on_heartbeat_error: Proc.new do
          @logger.fatal "parent process unexpectedly terminated"
          exit 1
        end
      )

      super(worker_module, load_config_proc, &block)

      @worker_process_name = @config[:worker_process_name]
    end

    def run
      super
    ensure
      @pm.close
    end

    def logger=(logger)
      super
      @pm.logger = logger
    end

    private

    def reload_config
      super

      @chuser = @config[:worker_chuser]
      @chgroup = @config[:worker_chgroup]
      @chumask = @config[:worker_chumask]

      @pm.configure(@config, prefix: 'worker_')

      nil
    end

    def start_worker(wid)
      w = create_worker(wid)

      w.before_fork
      begin
        pmon = @pm.fork do |t|
          $0 = @worker_process_name % [wid] if @worker_process_name
          w.install_signal_handlers

          Privilege.change_privilege(@chuser, @chgroup)
          File.umask(@chumask) if @chumask

          ## recreate the logger created at Server#main
          #create_logger

          w.main
        end

      ensure
        w.after_start
      end

      return Monitor::ProcessWorkerMonitor.new(w, wid, pmon)
    end

    def wait_tick
      @pm.tick(0.5)
    end
  end
end
