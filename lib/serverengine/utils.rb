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

  IS_WINDOWS = /mswin|mingw/ === RUBY_PLATFORM
  IS_LINUX = /linux/ === RUBY_PLATFORM
  private_constant :IS_WINDOWS

  def self.windows?
    IS_WINDOWS
  end

  def self.linux?
    IS_LINUX
  end

  module ClassMethods
    def dump_uncaught_error(e)
      STDERR.write "Unexpected error #{e}\n"
      e.backtrace.each {|bt|
        STDERR.write "  #{bt}\n"
      }
      nil
    end

    def format_signal_name(n)
      Signal.list.each_pair {|k,v|
        return "SIG#{k}" if n == v
      }
      return n
    end

    def format_join_status(code)
      case code
      when Process::Status
        if code.signaled?
          "signal #{format_signal_name(code.termsig)}"
        else
          "status #{code.exitstatus}"
        end
      when Exception
        "exception #{code}"
      when nil
        "unknown reason"
      end
    end

  end

  extend ClassMethods

end
