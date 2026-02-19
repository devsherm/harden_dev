require_relative "test_helper"

class PipelineCiJoinTest < PipelineTestCase
  def setup
    super
    # Suppress expected exception noise from intentionally-failing threads
    Thread.report_on_exception = false
  end

  def teardown
    Thread.report_on_exception = true
    super
  end

  def stub_spawn_success
    @pipeline.define_singleton_method(:spawn_with_timeout) do |*cmd, timeout:, chdir: nil|
      ["OK", true]
    end
  end

  def stub_spawn_one_fails(fail_index:)
    call_count = 0
    mutex = Mutex.new
    @pipeline.define_singleton_method(:spawn_with_timeout) do |*cmd, timeout:, chdir: nil|
      idx = mutex.synchronize { call_count += 1; call_count }
      if idx == fail_index
        ["FAIL", false]
      else
        ["OK", true]
      end
    end
  end

  def stub_spawn_one_raises(raise_index:)
    call_count = 0
    mutex = Mutex.new
    @pipeline.define_singleton_method(:spawn_with_timeout) do |*cmd, timeout:, chdir: nil|
      idx = mutex.synchronize { call_count += 1; call_count }
      if idx == raise_index
        raise "Boom from thread #{idx}"
      else
        sleep 0.1
        ["OK", true]
      end
    end
  end

  def stub_spawn_all_raise
    @pipeline.define_singleton_method(:spawn_with_timeout) do |*cmd, timeout:, chdir: nil|
      raise "Boom"
    end
  end

  def test_all_checks_pass_returns_four_results
    stub_spawn_success
    results = @pipeline.send(:run_all_ci_checks, "app/controllers/test_controller.rb")
    assert_equal 4, results.length
    results.each { |r| assert r[:passed] }
  end

  def test_one_check_fails_still_returns_all_results
    stub_spawn_one_fails(fail_index: 2)
    results = @pipeline.send(:run_all_ci_checks, "app/controllers/test_controller.rb")
    assert_equal 4, results.length
    assert_equal 1, results.count { |r| !r[:passed] }
  end

  def test_exception_in_one_thread_joins_all_others
    stub_spawn_one_raises(raise_index: 1)
    assert_raises(RuntimeError) do
      @pipeline.send(:run_all_ci_checks, "app/controllers/test_controller.rb")
    end
    sleep 0.5
    live = @pipeline.instance_variable_get(:@threads).count(&:alive?)
    assert_equal 0, live, "Expected 0 live threads, got #{live}"
  end

  def test_all_threads_raise_still_joins_all
    stub_spawn_all_raise
    assert_raises(RuntimeError) do
      @pipeline.send(:run_all_ci_checks, "app/controllers/test_controller.rb")
    end
    sleep 0.5
    live = @pipeline.instance_variable_get(:@threads).count(&:alive?)
    assert_equal 0, live, "Expected 0 live threads, got #{live}"
  end
end
