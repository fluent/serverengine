require 'socket'

describe ServerEngine::SocketManager do
  include_context 'test server and worker'

  let(:server_path) do
    if ServerEngine.windows?
      24223
    else
      'tmp/socket_manager_test.sock'
    end
  end

  let(:test_port) do
    9101
  end

  after(:each) do
    File.unlink(server_path) if server_path.is_a?(String) && File.exist?(server_path)
  end

  context 'using ipv6' do
    it 'raises Errno::EADDRINUSE when try to bind the same port twice' do
      begin
        t1 = TCPServer.open("::1", test_port)
        t2 = nil
        expect{ t2 = TCPServer.open("::1", test_port) }.to raise_error(Errno::EADDRINUSE)
      ensure
        t1.close
        t2.close if t2
      end
    end
  end if (TCPServer.open("::1",0) rescue nil)

  context 'with thread' do
    context 'using ipv4' do
      it 'works' do
        server = SocketManager::Server.open(server_path)

        mutex = Mutex.new
        server_thread_started = false

        thread = Thread.new do
          mutex.lock
          server_thread_started = true

          begin
            client = ServerEngine::SocketManager::Client.new(server_path)

            tcp = client.listen_tcp('127.0.0.1', test_port)
            udp = client.listen_udp('127.0.0.1', test_port)

            incr_test_state(:is_tcp_server) if tcp.is_a?(TCPServer)
            incr_test_state(:is_udp_socket) if udp.is_a?(UDPSocket)

            mutex.unlock

            data, _from = udp.recvfrom(10)
            incr_test_state(:udp_data_sent) if data == "ok"

            s = tcp.accept
            s.write("ok")
            s.close
          rescue => e
            p(here: "rescue in server thread", error: e)
            e.backtrace.each do |bt|
              STDERR.puts bt
            end
            raise
          ensure
            tcp.close
            udp.close
          end
        end

        sleep 0.1 until server_thread_started
        sleep 0.1 while mutex.locked?

        u = UDPSocket.new(Socket::AF_INET)
        u.send "ok", 0, '127.0.0.1', test_port
        u.close

        t = TCPSocket.open('127.0.0.1', test_port)
        t.read.should == "ok"
        t.close

        server.close
        thread.join

        test_state(:is_tcp_server).should == 1
        test_state(:is_udp_socket).should == 1
        test_state(:udp_data_sent).should == 1
      end
    end

    context 'using ipv6' do
      it 'works' do
        server = SocketManager::Server.open(server_path)

        mutex = Mutex.new
        server_thread_started = false

        thread = Thread.new do
          Thread.current.abort_on_exception = true
          mutex.lock
          server_thread_started = true

          begin
            client = ServerEngine::SocketManager::Client.new(server_path)

            tcp = client.listen_tcp('::1', test_port)
            udp = client.listen_udp('::1', test_port)

            incr_test_state(:is_tcp_server) if tcp.is_a?(TCPServer)
            incr_test_state(:is_udp_socket) if udp.is_a?(UDPSocket)

            mutex.unlock

            data, _from = udp.recvfrom(10)
            incr_test_state(:udp_data_sent) if data == "ok"

            s = tcp.accept
            s.write("ok")
            s.close
          rescue => e
            p(here: "rescue in server thread", error: e)
            e.backtrace.each do |bt|
              STDERR.puts bt
            end
            raise
          ensure
            tcp.close
            udp.close
          end
        end

        sleep 0.1 until server_thread_started
        sleep 0.1 while mutex.locked?

        u = UDPSocket.new(Socket::AF_INET6)
        u.send "ok", 0, '::1', test_port
        u.close

        t = TCPSocket.open('::1', test_port)
        t.read.should == "ok"
        t.close

        server.close
        thread.join

        test_state(:is_tcp_server).should == 1
        test_state(:is_udp_socket).should == 1
        test_state(:udp_data_sent).should == 1
      end
    end if (TCPServer.open("::1",0) rescue nil)
  end

  if ServerEngine.windows?
    it 'is windows' do
      SocketManager::Client.is_a?(SocketManagerWin::ClientModule)
      SocketManager::Server.is_a?(SocketManagerWin::ServerModule)
    end
  else
    it 'is unix' do
      SocketManager::Client.is_a?(SocketManagerUnix::ClientModule)
      SocketManager::Server.is_a?(SocketManagerUnix::ServerModule)
    end

    context 'with fork' do
      it 'works' do
        server = SocketManager::Server.open(server_path)

        fork do
          server.close

          begin
            client = server.new_client

            tcp = client.listen_tcp('127.0.0.1', test_port)
            udp = client.listen_udp('127.0.0.1', test_port)

            incr_test_state(:is_tcp_server) if tcp.is_a?(TCPServer)
            incr_test_state(:is_udp_socket) if udp.is_a?(UDPSocket)

            data, _from = udp.recvfrom(10)
            incr_test_state(:udp_data_sent) if data == "ok"

            s = tcp.accept
            s.write("ok")
            s.close
          ensure
            tcp.close
            udp.close
          end
        end

        wait_for_fork

        u = UDPSocket.new
        u.send "ok", 0, '127.0.0.1', test_port
        u.close

        t = TCPSocket.open('127.0.0.1', test_port)
        t.read.should == "ok"
        t.close

        server.close

        test_state(:is_tcp_server).should == 1
        test_state(:is_udp_socket).should == 1
        test_state(:udp_data_sent).should == 1
      end
    end
  end

end
