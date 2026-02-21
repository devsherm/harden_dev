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

  def test_reset_releases_all_lock_manager_grants
    lock_manager = @pipeline.instance_variable_get(:@lock_manager)

    # Create a fake grant by directly inserting into the lock manager's grants hash
    grant = LockGrant.new(
      holder: "test_holder",
      write_paths: ["/fake/path.rb"]
    )
    lock_manager.instance_variable_get(:@grants)[grant.id] = grant

    assert_equal 1, lock_manager.active_grants.length, "Should have one active grant before reset"

    @pipeline.reset!

    assert_empty lock_manager.active_grants, "All grants should be released after reset"
  end

  def test_reset_stops_scheduler
    scheduler = @pipeline.instance_variable_get(:@scheduler)
    scheduler.start

    assert scheduler.instance_variable_get(:@dispatch_thread)&.alive?,
           "Scheduler dispatch thread should be running"

    @pipeline.reset!

    sleep 0.2
    refute scheduler.instance_variable_get(:@dispatch_thread)&.alive?,
           "Scheduler dispatch thread should be stopped after reset"
  end

  def test_to_json_includes_lock_state
    json = JSON.parse(@pipeline.to_json)

    assert json.key?("locks"), "to_json should include locks key"
    locks = json["locks"]
    assert locks.key?("active_grants"), "locks should include active_grants"
    assert locks.key?("queue_depth"), "locks should include queue_depth"
    assert locks.key?("active_items"), "locks should include active_items"
    assert_equal [], locks["active_grants"]
    assert_equal 0, locks["queue_depth"]
    assert_equal [], locks["active_items"]
  end

  def test_new_kwargs_have_correct_defaults
    pipeline = Pipeline.new(rails_root: @tmpdir)

    assert_equal ".enhance", pipeline.instance_variable_get(:@enhance_sidecar_dir)
    assert_equal ["app/controllers", "app/views", "app/models", "app/services", "test/"],
                 pipeline.instance_variable_get(:@enhance_allowed_write_paths)
    # api_key defaults to ENV["ANTHROPIC_API_KEY"] (may be nil in test env)
    expected_key = ENV["ANTHROPIC_API_KEY"]
    if expected_key.nil?
      assert_nil pipeline.instance_variable_get(:@api_key)
    else
      assert_equal expected_key, pipeline.instance_variable_get(:@api_key)
    end
    assert_instance_of LockManager, pipeline.instance_variable_get(:@lock_manager)
    assert_instance_of Scheduler, pipeline.instance_variable_get(:@scheduler)
  ensure
    pipeline&.shutdown(timeout: 2) rescue nil
  end

  def test_new_accepts_custom_lock_manager_and_scheduler
    mock_lm = Object.new
    def mock_lm.active_grants; []; end
    def mock_lm.release_all; end

    mock_sched = Object.new
    def mock_sched.queue_depth; 0; end
    def mock_sched.active_items; 0; end
    def mock_sched.start; self; end
    def mock_sched.stop; end

    pipeline = Pipeline.new(
      rails_root: @tmpdir,
      lock_manager: mock_lm,
      scheduler: mock_sched
    )

    assert_same mock_lm, pipeline.instance_variable_get(:@lock_manager)
    assert_same mock_sched, pipeline.instance_variable_get(:@scheduler)
  ensure
    pipeline.shutdown(timeout: 2) rescue nil
  end
end
