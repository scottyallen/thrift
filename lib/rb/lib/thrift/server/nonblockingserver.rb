require 'thrift/server'
require 'logger'
require 'thread'

module Thrift
  # this class expects to always use a FramedTransport for reading messages
  class NonblockingServer < Server
    def initialize(processor, serverTransport, transportFactory=nil, protocolFactory=nil, num=20, logger = nil)
      super(processor, serverTransport, transportFactory, protocolFactory)
      @num_threads = num
      if logger.nil?
        @logger = Logger.new(STDERR)
        @logger.level = Logger::WARN
      else
        @logger = logger
      end
      @shutdown_semaphore = Mutex.new
    end

    def serve
      @logger.info "Starting #{self}"
      @serverTransport.listen
      @io_manager = start_io_manager

      begin
        loop do
          socket = @serverTransport.accept
          @logger.debug "Accepted socket: #{socket.inspect}"
          @io_manager.add_connection socket
        end
      rescue IOError => e
        # we must be shutting down
        @logger.info "#{self} is shutting down, goodbye"
      end
    ensure
      @serverTransport.close
      @io_manager.ensure_closed unless @io_manager.nil?
    end

    def shutdown(timeout = 0, block = true)
      @shutdown_semaphore.synchronize do
        return if @is_shutdown
        @is_shutdown = true
      end
      # nonblocking is intended for calling from within a Handler
      # but we can't change the order of operations here, so lets thread
      shutdown_proc = lambda do
        @io_manager.shutdown(timeout)
        @serverTransport.close # this will break the accept loop
      end
      if block
        shutdown_proc.call
      else
        Thread.new &shutdown_proc
      end
    end

    private

    def start_io_manager
      iom = IOManager.new(@processor, @serverTransport, @transportFactory, @protocolFactory, @num_threads, @logger)
      iom.spawn
      iom
    end

    class IOManager # :nodoc:
      def initialize(processor, serverTransport, transportFactory, protocolFactory, num, logger)
        @processor = processor
        @serverTransport = serverTransport
        @transportFactory = transportFactory
        @protocolFactory = protocolFactory
        @num_threads = num
        @logger = logger
        @connections = []
        @buffers = Hash.new { |h,k| h[k] = '' }
        @signal_queue = Queue.new
        @signal_pipes = IO.pipe
        @signal_pipes[1].sync = true
        @worker_queue = Queue.new
        @shutdown_queue = Queue.new
      end

      def add_connection(socket)
        signal [:connection, socket]
      end

      def spawn
        @iom_thread = Thread.new do
          @logger.debug "Starting #{self}"
          run
        end
      end

      def shutdown(timeout = 0)
        @logger.debug "#{self} is shutting down workers"
        @worker_queue.clear
        @num_threads.times { @worker_queue.push [:shutdown] }
        signal [:shutdown, timeout]
        @shutdown_queue.pop
        @signal_pipes[0].close
        @signal_pipes[1].close
        @logger.debug "#{self} is shutting down, goodbye"
      end

      def ensure_closed
        kill_worker_threads if @worker_threads
        @iom_thread.kill
      end

      private

      def run
        spin_worker_threads

        loop do
          rd, = select([@signal_pipes[0], *@connections])
          if rd.delete @signal_pipes[0]
            break if read_signals == :shutdown
          end
          rd.each do |fd|
            if fd.handle.eof?
              remove_connection fd
            else
              read_connection fd
            end
          end
        end
        join_worker_threads(@shutdown_timeout)
      ensure
        @shutdown_queue.push :shutdown
      end

      def read_connection(fd)
        buffer = ''
        begin
          buffer << fd.read_nonblock(4096) while true
        rescue Errno::EAGAIN, EOFError
          @buffers[fd] << buffer
        end
        frame = slice_frame!(@buffers[fd])
        if frame
          @worker_queue.push [:frame, fd, frame]
        end
      end

      def spin_worker_threads
        @logger.debug "#{self} is spinning up worker threads"
        @worker_threads = []
        @num_threads.times do
          @worker_threads << spin_thread
        end
      end

      def spin_thread
        Worker.new(@processor, @transportFactory, @protocolFactory, @logger, @worker_queue).spawn
      end

      def signal(msg)
        @signal_queue << msg
        @signal_pipes[1].write " "
      end

      def read_signals
        # clear the signal pipe
        begin
          @signal_pipes[0].read_nonblock(1024) while true
        rescue Errno::EAGAIN
        end
        # now read the signals
        begin
          loop do
            signal, obj = @signal_queue.pop(true)
            case signal
            when :connection
              @connections << obj
            when :shutdown
              @shutdown_timeout = obj
              return :shutdown
            end
          end
        rescue ThreadError
          # out of signals
        end
      end

      def remove_connection(fd)
        # don't explicitly close it, a thread may still be writing to it
        @connections.delete fd
        @buffers.delete fd
      end

      def join_worker_threads(shutdown_timeout)
        start = Time.now
        @worker_threads.each do |t|
          if shutdown_timeout > 0
            timeout = Time.now - (start + shutdown_timeout)
            break if timeout <= 0
            t.join(timeout)
          else
            t.join
          end
        end
        kill_worker_threads
      end

      def kill_worker_threads
        @worker_threads.each do |t|
          t.kill if t.status
        end
        @worker_threads.clear
      end

      def slice_frame!(buf)
        if buf.length >= 4
          size = buf.unpack('N').first
          if buf.length >= size + 4
            buf.slice!(0, size + 4)
          else
            nil
          end
        else
          nil
        end
      end

      class Worker # :nodoc:
        def initialize(processor, transportFactory, protocolFactory, logger, queue)
          @processor = processor
          @transportFactory = transportFactory
          @protocolFactory = protocolFactory
          @logger = logger
          @queue = queue
        end

        def spawn
          Thread.new do
            @logger.debug "#{self} is spawning"
            run
          end
        end

        private

        def run
          loop do
            cmd, *args = @queue.pop
            case cmd
            when :shutdown
              @logger.debug "#{self} is shutting down, goodbye"
              break
            when :frame
              fd, frame = args
              begin
                otrans = @transportFactory.get_transport(fd)
                oprot = @protocolFactory.get_protocol(otrans)
                membuf = MemoryBuffer.new(frame)
                itrans = @transportFactory.get_transport(membuf)
                iprot = @protocolFactory.get_protocol(itrans)
                @processor.process(iprot, oprot)
              rescue => e
                @logger.error "#{Thread.current.inspect} raised error: #{e.inspect}\n#{e.backtrace.join("\n")}"
              end
            end
          end
        end
      end
    end
  end
end