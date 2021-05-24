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
require 'logger'
require 'serverengine/utils'

module ServerEngine

  class ::Logger::LogDevice
    def reopen!
      if filename = @filename
        @dev.reopen(filename, 'a')
        @dev.sync = true
      end
    end
  end

  class DaemonLogger < Logger
    def initialize(logdev, config={})
      @rotate_age = config[:log_rotate_age] || 5
      @rotate_size = config[:log_rotate_size] || 1048576
      @file_dev = nil

      super(nil)

      if ServerEngine::linux?
        begin
          require 'rb-inotify'
        rescue LoadError
        end
      end

      self.level = config[:log_level] || 'debug'
      self.logdev = logdev
    end

    def logdev=(logdev)
      # overwrites Logger's @logdev variable
      if logdev.respond_to?(:write) and logdev.respond_to?(:close)
        # IO
        @logdev = logdev
        @logdev.sync = true if @logdev.respond_to?(:sync=)
        if @file_dev
          old_file_dev = @file_dev
          @file_dev = nil
          old_file_dev.close
        end
      elsif !@file_dev || @file_dev.filename != logdev
        # update path string
        old_file_dev = @file_dev
        @file_dev = LogDevice.new(logdev, shift_age: @rotate_age, shift_size: @rotate_size)
        old_file_dev.close if old_file_dev
        @logdev = @file_dev
      end
      enable_watching_logdev(logdev) if defined?(INotify)
      logdev
    end

    # override add method
    def add(severity, message = nil, progname = nil, &block)
      if severity < @level
        return true
      end
      if message.nil?
        if block_given?
          message = yield
        else
          message = progname
          progname = nil
        end
      end
      progname ||= @progname
      self << format_message(SEVERITY_FORMATS_[severity+1], Time.now, progname, message)
      poll_pending_inotify if defined?(INotify)
      true
    end

    def poll_pending_inotify
      return unless ServerEngine::linux?
      return unless @inotify

      if IO.select([@inotify.to_io], [], [], 0)
        @inotify.process
      end
    end

    def enable_watching_logdev(logdev)
      return unless ServerEngine::linux?

      target = nil
      if logdev.respond_to?(:filename)
        target = logdev.filename
      elsif logdev.respond_to?(:path)
        target = logdev.path
      elsif logdev.is_a?(String)
        target = logdev
      else
        # ignore StringIO for some test cases
        return
      end
      if target
        @inotify.close if @inotify
        @inotify = INotify::Notifier.new
        @inotify.watch(target, :move_self) do |event|
          if @logdev.respond_to?(:filename)
            @logdev.close
            @logdev.reopen(@logdev.filename)
          elsif @logdev.respond_to?(:path)
            @logdev.close
            @logdev.reopen(@logdev.path)
          else
            close
            reopen
          end
        end
      end
    end

    module Severity
      include Logger::Severity
      TRACE = -1
    end
    include Severity

    SEVERITY_FORMATS_ = %w(TRACE DEBUG INFO WARN ERROR FATAL ANY)

    def level=(expr)
      case expr.to_s
      when 'fatal', FATAL.to_s
        e = FATAL
      when 'error', ERROR.to_s
        e = ERROR
      when 'warn', WARN.to_s
        e = WARN
      when 'info', INFO.to_s
        e = INFO
      when 'debug', DEBUG.to_s
        e = DEBUG
      when 'trace', TRACE.to_s
        e = TRACE
      else
        raise ArgumentError, "invalid log level: #{expr}"
      end

      super(e)
    end

    def trace?; @level <= TRACE; end

    def reopen!
      @file_dev.reopen! if @file_dev
      nil
    end

    def reopen
      begin
        reopen!
        return true
      rescue
        # TODO log?
        return false
      end
    end

    def close
      @file_dev.close if @file_dev
      nil
    end

  end

end
