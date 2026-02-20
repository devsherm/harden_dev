# frozen_string_literal: true

class Pipeline
  module ProcessManagement
    def safe_thread(workflow_name: nil, &block)
      t = Thread.new do
        raise "Pipeline is shutting down" if cancelled?
        block.call
      rescue => e
        if workflow_name
          @mutex.synchronize do
            wf = @state[:workflows][workflow_name]
            if wf && wf[:status] != "error"
              wf[:error] = sanitize_error(e.message)
              wf[:status] = "error"
              add_error("Thread failed for #{workflow_name}: #{e.message}")
            end
          end
        end
        $stderr.puts "[safe_thread] #{workflow_name || 'unnamed'} died: #{e.class}: #{e.message}"
        $stderr.puts e.backtrace.first(5).join("\n")
      end
      @mutex.synchronize do
        @threads.reject! { |t| !t.alive? }
        @threads << t
      end
      t
    end

    def cancel!
      @cancelled = true  # Atomic in CRuby (GVL), safe without mutex
    end

    def cancelled?
      @cancelled  # Atomic in CRuby (GVL), safe without mutex — matches cancel!
    end

    def shutdown(timeout: 5)
      threads = @mutex.synchronize do
        @cancelled = true
        @threads.dup
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      threads.each do |t|
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        t.join([remaining, 0].max)
      end
      threads.each { |t| t.kill if t.alive? }
    end

    private

    def spawn_with_timeout(*cmd, timeout:, chdir: nil)
      rd, wr = IO.pipe
      opts = { [:out, :err] => wr }
      opts[:chdir] = chdir if chdir
      pid = Process.spawn(*cmd, **opts, pgroup: true)
      wr.close
      reaped = false

      output = +""
      reader = Thread.new { output << rd.read }

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        result = Process.wait2(pid, Process::WNOHANG)
        if result
          reaped = true
          _, status = result
          reader.join(5)
          return [output, status.success?]
        end
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline || cancelled?
          Process.kill("-TERM", pid) rescue Errno::ESRCH
          sleep 0.5
          Process.kill("-KILL", pid) rescue Errno::ESRCH
          Process.wait2(pid) rescue nil
          reaped = true
          reason = cancelled? ? "Pipeline cancelled" : "Command timed out after #{timeout}s: #{cmd.join(' ')}"
          raise reason
        end
        sleep 0.1
      end
    ensure
      unless reaped
        Process.kill("-KILL", pid) rescue Errno::ESRCH
        Process.wait2(pid) rescue nil
      end
      wr&.close unless wr&.closed?
      rd&.close unless rd&.closed?
      reader&.join(2)
    end

    def run_all_ci_checks(controller_relative)
      ci_threads = CI_CHECKS.map do |check|
        cmd = check[:cmd].call(controller_relative)
        t = Thread.new do
          output, passed = spawn_with_timeout(*cmd, timeout: COMMAND_TIMEOUT, chdir: @rails_root)
          { name: check[:name], command: cmd.join(" "), passed: passed, output: output }
        end
        @mutex.synchronize do
          @threads.reject! { |th| !th.alive? }
          @threads << t
        end
        t
      end
      results = ci_threads.map { |t| t.value rescue $! }
      first_error = results.find { |r| r.is_a?(Exception) }
      if first_error
        ci_threads.each { |t| t.kill if t.alive? }
        ci_threads.each { |t| t.join(2) }
        raise first_error
      end
      results
    end
  end
end
