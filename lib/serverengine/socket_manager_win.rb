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
require 'socket'
require 'ipaddr'

require_relative 'winsock'

module ServerEngine
  module SocketManagerWin

    module ClientModule
      private

      def connect_peer(addr)
        return TCPSocket.open("127.0.0.1", addr)
      end

      def recv(family, proto, peer, sent)
        server_class, protocol = case proto
                                 when :tcp then [TCPServer, Socket::SOCK_STREAM]
                                 when :udp then [UDPSocket, Socket::SOCK_DGRAM]
                                 else
                                   raise ArgumentError, "invalid protocol: #{proto}"
                                 end

        proto_info = WinSock::WSAPROTOCOL_INFO.from_bin(sent)

        handle = WinSock.WSASocketA(family, protocol, 0, proto_info, 0, 1)
        if handle == WinSock::INVALID_SOCKET
          RbWinSock.raise_last_error("WSASocketA(2)")
        end

        return RbWinSock.wrap_io_handle(server_class, handle, 0)
      end

      def recv_tcp(family, peer, sent)
        recv(family, :tcp, peer, sent)
      end

      def recv_udp(family, peer, sent)
        recv(family, :udp, peer, sent)
      end
    end

    module ServerModule
      private

      TCP_OPTIONS = [Socket::SOCK_STREAM, Socket::IPPROTO_TCP, TCPServer, true]
      UDP_OPTIONS = [Socket::SOCK_DGRAM, Socket::IPPROTO_UDP, UDPSocket, false]

      def listen_new(proto, bind_ip, port)
        protocol, proto_info, klass, listen = case proto
                                              when :tcp then TCP_OPTIONS
                                              when :udp then UDP_OPTIONS
                                              else
                                                raise ArgumentError, "invalid protocol: #{proto}"
                                              end
        family = bind_ip.ipv6? ? Socket::AF_INET6 : Socket::AF_INET

        sock_addr = Socket.pack_sockaddr_in(port, bind_ip.to_s)

        handle = WinSock.WSASocketA(family, protocol, proto_info, nil, 0, 1)
        if handle == WinSock::INVALID_SOCKET
          RbWinSock.raise_last_error("WSASocketA(2)")
        end

        # wrap in TCPServer/UDPSocket immediately so that its finalizer safely closes the handle
        sock = RbWinSock.wrap_io_handle(klass, handle, 0)

        unless WinSock.bind(sock.handle, sock_addr, sock_addr.bytesize) == 0
          RbWinSock.raise_last_error("bind(2)")
        end

        if listen
          unless WinSock.listen(sock.handle, Socket::SOMAXCONN) == 0
            RbWinSock.raise_last_error("listen(2)")
          end
        end

        sock
      end

      def listen_tcp_new(bind_ip, port)
        listen_new(:tcp, bind_ip, port)
      end

      def listen_udp_new(bind_ip, port)
        listen_new(:udp, bind_ip, port)
      end

      def htons(h)
        [h].pack("S").unpack("n")[0]
      end

      def start_server(addr)
        # TODO: use TCPServer, but this is risky because using not conflict path is easy,
        # but using not conflict port is difficult. Then We had better implement using NamedPipe.
        @server = TCPServer.new("127.0.0.1", addr)
        @thread = Thread.new do
          if Thread.current.respond_to?(:report_on_exception=)
            # TODO: make this default when ruby 2.3 or earlier are outdated
            Thread.current.report_on_exception = true
          end

          begin
            while peer = @server.accept
              Thread.new(peer, &method(:process_peer))  # process_peer calls send_socket
            end
          rescue => e
            if @server.closed?
              # ignore error raised about tcp socket now closed in another thread
            else
              begin
                ServerEngine.dump_uncaught_error(e)
              rescue IOError => e2 # STDERR is closed or unavailable with other reasons
                raise e # Ruby runtime can show this if Thread#report_on_exception is available
              end
            end
          end
        end

        return path
      end

      def stop_server
        @tcp_sockets.reject! {|key,lsock| lsock.close; true }
        @udp_sockets.reject! {|key,usock| usock.close; true }
        @server.close unless @server.closed?
        @thread.join
      end

      def send_socket(peer, pid, method, bind, port)
        case method
        when :listen_tcp
          sock = listen_tcp(bind, port)
          type = Socket::SOCK_STREAM
        when :listen_udp
          sock = listen_udp(bind, port)
          type = Socket::SOCK_DGRAM
        else
          raise ArgumentError, "Unknown method: #{method.inspect}"
        end

        proto = WinSock::WSAPROTOCOL_INFO.malloc
        unless WinSock.WSADuplicateSocketA(sock.handle, pid, proto) == 0
          RbWinSock.raise_last_error("WSADuplicateSocketA(3)")
        end

        SocketManager.send_peer(peer, proto.to_bin)
      end
    end
  end
end
