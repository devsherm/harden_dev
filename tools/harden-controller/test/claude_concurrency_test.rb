# frozen_string_literal: true

require_relative "test_helper"

class ClaudeConcurrencyTest < PipelineTestCase
  # Use a small concurrency cap for testing
  TEST_CONCURRENCY = 2

  def setup
    super
    @original_max = Pipeline::MAX_CLAUDE_CONCURRENCY
    Pipeline.send(:remove_const, :MAX_CLAUDE_CONCURRENCY)
    Pipeline.const_set(:MAX_CLAUDE_CONCURRENCY, TEST_CONCURRENCY)
    @original_report_on_exception = Thread.report_on_exception
    Thread.report_on_exception = false
  end

  def teardown
    Pipeline.send(:remove_const, :MAX_CLAUDE_CONCURRENCY)
    Pipeline.const_set(:MAX_CLAUDE_CONCURRENCY, @original_max)
    Thread.report_on_exception = @original_report_on_exception
    super
  end

  def test_can_acquire_up_to_max_slots
    TEST_CONCURRENCY.times { @pipeline.send(:acquire_claude_slot) }

    active = @pipeline.instance_variable_get(:@claude_active)
    assert_equal TEST_CONCURRENCY, active
  ensure
    TEST_CONCURRENCY.times { @pipeline.send(:release_claude_slot) }
  end

  def test_slot_beyond_max_blocks_until_released
    # Fill all slots
    TEST_CONCURRENCY.times { @pipeline.send(:acquire_claude_slot) }

    acquired = false
    blocker = Thread.new do
      @pipeline.send(:acquire_claude_slot)
      acquired = true
    end

    # Give the thread time to start waiting
    sleep 0.1
    refute acquired, "Thread should be blocked waiting for a slot"

    # Release one slot to unblock
    @pipeline.send(:release_claude_slot)
    blocker.join(3)

    assert acquired, "Thread should have acquired slot after release"
  ensure
    # Clean up all acquired slots
    active = @pipeline.instance_variable_get(:@claude_active)
    active.times { @pipeline.send(:release_claude_slot) }
  end

  def test_cancelled_pipeline_unblocks_waiting_acquirer
    # Fill all slots
    TEST_CONCURRENCY.times { @pipeline.send(:acquire_claude_slot) }

    error = nil
    waiter = Thread.new do
      begin
        @pipeline.send(:acquire_claude_slot)
      rescue => e
        error = e
      end
    end

    # Give thread time to enter wait
    sleep 0.1

    # Cancel the pipeline — waiter checks cancelled? after each 5s wait cycle
    # but we can signal the condition variable to wake it sooner
    @pipeline.cancel!
    @pipeline.instance_variable_get(:@claude_semaphore).synchronize do
      @pipeline.instance_variable_get(:@claude_slots).broadcast
    end

    waiter.join(6)
    refute waiter.alive?, "Waiter should have exited after cancellation"
    assert_kind_of RuntimeError, error
    assert_match(/cancelled/i, error.message)
  ensure
    active = @pipeline.instance_variable_get(:@claude_active)
    active.times { @pipeline.send(:release_claude_slot) }
  end

  def test_release_decrements_and_unblocks
    @pipeline.send(:acquire_claude_slot)
    assert_equal 1, @pipeline.instance_variable_get(:@claude_active)

    @pipeline.send(:release_claude_slot)
    assert_equal 0, @pipeline.instance_variable_get(:@claude_active)
  end
end
