require_relative "test_helper"

class PipelineResetTest < PipelineTestCase
  def test_reset_clears_state
    @pipeline.instance_variable_get(:@mutex).synchronize do
      @pipeline.instance_variable_get(:@state)[:phase] = "discovering"
      @pipeline.instance_variable_get(:@state)[:controllers] << { name: "test" }
      @pipeline.instance_variable_get(:@state)[:errors] << { message: "err" }
    end

    @pipeline.reset!

    assert_equal "idle", @pipeline.phase
    state = @pipeline.instance_variable_get(:@state)
    assert_empty state[:controllers]
    assert_empty state[:workflows]
    assert_empty state[:errors]
  end

  def test_reset_clears_cancelled_flag
    @pipeline.cancel!
    assert @pipeline.cancelled?

    @pipeline.reset!

    refute @pipeline.cancelled?
  end

  def test_reset_joins_active_threads
    blocker = Queue.new
    @pipeline.safe_thread { blocker.pop }
    threads_before = @pipeline.instance_variable_get(:@threads).dup

    assert threads_before.any?(&:alive?)

    @pipeline.reset!

    threads_before.each { |t| refute t.alive?, "Thread should be dead after reset" }
    assert_empty @pipeline.instance_variable_get(:@threads)
  end

  def test_thread_added_during_shutdown_is_drained
    sneaky_thread = nil
    original_shutdown = @pipeline.method(:shutdown)

    @pipeline.define_singleton_method(:shutdown) do |timeout: 5|
      original_shutdown.call(timeout: timeout)
      # Simulate a thread already past the cancelled? check when shutdown was called.
      # Use raw Thread.new to bypass safe_thread's guard.
      sneaky_thread = Thread.new { sleep 10 }
      @mutex.synchronize { @threads << sneaky_thread }
    end

    @pipeline.reset!
    sleep 0.2

    refute sneaky_thread&.alive?,
           "Thread added during reset race window should be cleaned up"
  end

  def test_reset_under_concurrent_load
    threads = 10.times.map do
      @pipeline.safe_thread { sleep 10 }
    end

    reset_thread = Thread.new { @pipeline.reset! }
    reset_thread.join(10)

    sleep 0.2
    threads.each do |t|
      refute t.alive?, "Thread should be dead after concurrent reset"
    end
  end
end
