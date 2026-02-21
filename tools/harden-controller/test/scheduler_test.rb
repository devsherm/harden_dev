# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../pipeline/lock_manager"
require_relative "../pipeline/scheduler"

# ── Test helpers ─────────────────────────────────────────────────────────────

# A mock LockManager that always grants locks unless told otherwise.
class MockLockManager
  attr_reader :acquire_calls, :release_calls

  def initialize(always_grant: true)
    @always_grant = always_grant
    @acquire_calls = []
    @release_calls = []
    @mutex = Mutex.new
  end

  def try_acquire(holder:, write_paths:)
    @mutex.synchronize { @acquire_calls << { holder: holder, write_paths: write_paths } }
    if @always_grant
      LockGrant.new(holder: holder, write_paths: write_paths)
    else
      nil
    end
  end

  def release(grant_id)
    @mutex.synchronize { @release_calls << grant_id }
    true
  end

  def release_all
    # no-op for mock
  end
end

# Builds a WorkItem with sensible defaults for tests.
def make_item(phase: :e_analyzing, write_paths: [], callback: -> (_grant_id) {}, **kwargs)
  WorkItem.new(
    workflow: "test_workflow",
    phase: phase,
    lock_request: LockRequest.new(write_paths: write_paths),
    callback: callback,
    **kwargs
  )
end

# Waits up to max_wait seconds for condition to become true (polling every 0.05s).
def wait_until(max_wait: 2)
  deadline = Time.now + max_wait
  loop do
    return true if yield
    break if Time.now > deadline
    sleep 0.05
  end
  false
end

# ── Scheduler tests ──────────────────────────────────────────────────────────

class SchedulerTest < Minitest::Test
  def setup
    @lock_manager = MockLockManager.new(always_grant: true)
    @slot_available = true
    @dispatched_threads = []
    @dispatched_mutex = Mutex.new

    @slot_available_fn = -> { @slot_available }
    @safe_thread_fn = ->(block = nil, &blk) {
      fn = block || blk
      t = Thread.new { fn.call }
      @dispatched_mutex.synchronize { @dispatched_threads << t }
      t
    }

    @scheduler = Scheduler.new(
      lock_manager: @lock_manager,
      slot_available_fn: @slot_available_fn,
      safe_thread_fn: @safe_thread_fn
    )
  end

  def teardown
    @scheduler.stop
    @dispatched_mutex.synchronize { @dispatched_threads.each { |t| t.join(2) rescue nil } }
  end

  # ── enqueue ────────────────────────────────────────────────────────────────

  def test_enqueue_adds_item_to_queue
    item = make_item
    @scheduler.enqueue(item)

    assert_equal 1, @scheduler.queue_depth
  end

  def test_enqueue_multiple_items
    3.times { @scheduler.enqueue(make_item) }

    assert_equal 3, @scheduler.queue_depth
  end

  def test_enqueue_returns_the_work_item
    item = make_item
    result = @scheduler.enqueue(item)

    assert_same item, result
  end

  # ── dispatch loop ──────────────────────────────────────────────────────────

  def test_dispatch_loop_dispatches_queued_item
    dispatched = false
    item = make_item(callback: ->(_) { dispatched = true })
    @scheduler.enqueue(item)
    @scheduler.start

    assert wait_until { dispatched }, "Item should have been dispatched"
  end

  def test_dispatch_loop_removes_item_from_queue_after_dispatch
    barrier = Mutex.new
    wait_cv = ConditionVariable.new
    proceed = false

    item = make_item(callback: ->(_) {
      barrier.synchronize { wait_cv.wait(barrier) until proceed }
    })

    @scheduler.enqueue(item)
    @scheduler.start

    # Wait until item is active (queue empty, active non-zero)
    assert wait_until { @scheduler.queue_depth == 0 && @scheduler.active_items > 0 },
           "Item should move from queue to active"

    # Unblock callback
    barrier.synchronize { proceed = true; wait_cv.signal }
  end

  def test_no_dispatch_when_slot_not_available
    @slot_available = false
    item = make_item(callback: ->(_) { flunk "Should not dispatch" })
    @scheduler.enqueue(item)
    @scheduler.start

    sleep 0.3  # Give dispatch loop time to run a few cycles
    assert_equal 1, @scheduler.queue_depth, "Item should still be in queue"
  end

  # ── priority ordering ──────────────────────────────────────────────────────

  def test_priority_e_applying_dispatched_before_e_analyzing
    dispatch_order = []
    order_mutex = Mutex.new

    # Prevent slots from being available initially so items queue up
    @slot_available = false

    analyzing = make_item(phase: :e_analyzing, callback: ->(_) {
      order_mutex.synchronize { dispatch_order << :e_analyzing }
    })
    applying = make_item(phase: :e_applying, callback: ->(_) {
      order_mutex.synchronize { dispatch_order << :e_applying }
    })

    # Enqueue lower-priority first to ensure sorting works
    @scheduler.enqueue(analyzing)
    @scheduler.enqueue(applying)
    @scheduler.start

    # Now allow slot — but only enough time for one dispatch cycle at a time
    # Use a counter to allow one item at a time
    dispatch_count = 0
    @slot_available_fn = -> {
      count = order_mutex.synchronize { dispatch_count }
      count < 1
    }
    @scheduler.instance_variable_set(:@slot_available_fn, @slot_available_fn)
    @slot_available = true

    # Allow dispatch to proceed
    assert wait_until(max_wait: 3) { order_mutex.synchronize { dispatch_order.length >= 1 } },
           "At least one item should have dispatched"

    # First dispatched item should be e_applying (higher priority)
    assert_equal :e_applying, order_mutex.synchronize { dispatch_order.first },
                 "e_applying should have higher priority than e_analyzing"
  end

  def test_priority_e_extracting_dispatched_before_e_analyzing
    dispatch_order = []
    order_mutex = Mutex.new

    @slot_available = false

    analyzing = make_item(phase: :e_analyzing, callback: ->(_) {
      order_mutex.synchronize { dispatch_order << :e_analyzing }
    })
    extracting = make_item(phase: :e_extracting, callback: ->(_) {
      order_mutex.synchronize { dispatch_order << :e_extracting }
    })

    @scheduler.enqueue(analyzing)
    @scheduler.enqueue(extracting)
    @scheduler.start

    dispatch_count = 0
    @slot_available_fn = -> {
      count = order_mutex.synchronize { dispatch_count }
      count < 1
    }
    @scheduler.instance_variable_set(:@slot_available_fn, @slot_available_fn)
    @slot_available = true

    assert wait_until(max_wait: 3) { order_mutex.synchronize { dispatch_order.length >= 1 } },
           "At least one item should have dispatched"

    assert_equal :e_extracting, order_mutex.synchronize { dispatch_order.first },
                 "e_extracting should have higher priority than e_analyzing"
  end

  def test_priority_e_applying_dispatched_before_e_extracting
    dispatch_order = []
    order_mutex = Mutex.new

    @slot_available = false

    extracting = make_item(phase: :e_extracting, callback: ->(_) {
      order_mutex.synchronize { dispatch_order << :e_extracting }
    })
    applying = make_item(phase: :e_applying, callback: ->(_) {
      order_mutex.synchronize { dispatch_order << :e_applying }
    })

    @scheduler.enqueue(extracting)
    @scheduler.enqueue(applying)
    @scheduler.start

    dispatch_count = 0
    @slot_available_fn = -> {
      count = order_mutex.synchronize { dispatch_count }
      count < 1
    }
    @scheduler.instance_variable_set(:@slot_available_fn, @slot_available_fn)
    @slot_available = true

    assert wait_until(max_wait: 3) { order_mutex.synchronize { dispatch_order.length >= 1 } },
           "At least one item should have dispatched"

    assert_equal :e_applying, order_mutex.synchronize { dispatch_order.first },
                 "e_applying should have higher priority than e_extracting"
  end

  # ── starvation prevention ─────────────────────────────────────────────────

  def test_starvation_prevention_promotes_old_items
    @slot_available = false

    # Create a high priority item queued now
    applying = make_item(phase: :e_applying, callback: ->(_) {})

    # Create a low priority item that is very old (simulate starvation)
    old_analyzing = make_item(
      phase: :e_analyzing,
      queued_at: Time.now - 700,  # 700 seconds ago, > 600 starvation threshold
      callback: ->(_) {}
    )

    @scheduler.enqueue(applying)
    @scheduler.enqueue(old_analyzing)

    # Check effective priority: old item should have priority -1 (beats e_applying's 0)
    effective_priorities = [applying, old_analyzing].map do |item|
      @scheduler.send(:effective_priority, item)
    end

    # applying has priority 0, old_analyzing has priority -1 (starvation escape)
    assert_equal 0, effective_priorities[0], "e_applying should have priority 0"
    assert_equal(-1, effective_priorities[1], "Starved item should have priority -1")
  end

  def test_starvation_threshold_not_reached_keeps_normal_priority
    item = make_item(phase: :e_analyzing, queued_at: Time.now - 100)  # only 100s old

    priority = @scheduler.send(:effective_priority, item)

    assert_equal 2, priority, "e_analyzing without starvation should have priority 2"
  end

  # ── lock acquisition ──────────────────────────────────────────────────────

  def test_dispatch_acquires_lock_for_items_with_write_paths
    dispatched_grant_id = nil
    item = make_item(
      write_paths: ["/fake/path/controller.rb"],
      callback: ->(grant_id) { dispatched_grant_id = grant_id }
    )

    @scheduler.enqueue(item)
    @scheduler.start

    assert wait_until { !dispatched_grant_id.nil? }, "Item should be dispatched with a grant"
    refute_nil dispatched_grant_id
    assert @lock_manager.acquire_calls.any?, "LockManager.try_acquire should have been called"
  end

  def test_dispatch_skips_locked_items
    blocking_lock_manager = MockLockManager.new(always_grant: false)
    scheduler = Scheduler.new(
      lock_manager: blocking_lock_manager,
      slot_available_fn: -> { true },
      safe_thread_fn: @safe_thread_fn
    )

    dispatched = false
    item = make_item(
      write_paths: ["/fake/path/controller.rb"],
      callback: ->(_) { dispatched = true }
    )

    scheduler.enqueue(item)
    scheduler.start

    sleep 0.3  # Give dispatch loop time to run
    refute dispatched, "Item with locked paths should not be dispatched"
  ensure
    scheduler.stop
  end

  def test_dispatch_releases_lock_after_callback
    released_grant_ids = []
    grant_id_assigned = nil

    # Custom lock manager to track releases
    custom_lm = MockLockManager.new(always_grant: true)
    scheduler = Scheduler.new(
      lock_manager: custom_lm,
      slot_available_fn: -> { true },
      safe_thread_fn: @safe_thread_fn
    )

    item = make_item(
      write_paths: ["/fake/path/controller.rb"],
      callback: ->(grant_id) { grant_id_assigned = grant_id }
    )

    scheduler.enqueue(item)
    scheduler.start

    assert wait_until { grant_id_assigned || custom_lm.release_calls.any? },
           "Callback should have run"

    # Wait for release
    assert wait_until { custom_lm.release_calls.any? }, "Lock should be released after callback"
    assert_includes custom_lm.release_calls, grant_id_assigned
  ensure
    scheduler.stop
  end

  def test_dispatch_no_lock_for_empty_write_paths
    dispatched_grant_id = :not_set
    item = make_item(
      write_paths: [],
      callback: ->(grant_id) { dispatched_grant_id = grant_id }
    )

    @scheduler.enqueue(item)
    @scheduler.start

    assert wait_until { dispatched_grant_id != :not_set }, "Item should be dispatched"
    assert_nil dispatched_grant_id, "No lock grant for empty write_paths"
    assert_empty @lock_manager.acquire_calls, "try_acquire should not be called for empty paths"
  end

  # ── graceful shutdown ─────────────────────────────────────────────────────

  def test_stop_waits_for_active_items
    barrier = Mutex.new
    cv = ConditionVariable.new
    proceed = false
    callback_ran = false

    item = make_item(callback: ->(_) {
      barrier.synchronize { cv.wait(barrier) until proceed }
      callback_ran = true
    })

    @scheduler.enqueue(item)
    @scheduler.start

    # Wait until item is active
    assert wait_until { @scheduler.active_items > 0 }, "Item should be active"

    # Start stop in background (it should wait for active items)
    stop_thread = Thread.new { @scheduler.stop }

    sleep 0.1  # Give stop a moment to initiate
    # Item should still be active (stop is waiting)
    assert @scheduler.active_items > 0 || callback_ran,
           "Active item should prevent immediate stop"

    # Now unblock the callback
    barrier.synchronize { proceed = true; cv.signal }
    stop_thread.join(3)

    assert callback_ran, "Callback should have completed before stop returned"
  end

  def test_stop_does_not_dispatch_new_items_after_shutdown
    # Start, then stop, then enqueue — item should not dispatch
    @scheduler.start
    @scheduler.stop

    dispatched = false
    item = make_item(callback: ->(_) { dispatched = true })
    @scheduler.enqueue(item)

    sleep 0.3
    refute dispatched, "Item enqueued after stop should not be dispatched"
  end

  # ── active_items / queue_depth ────────────────────────────────────────────

  def test_active_items_zero_initially
    assert_equal 0, @scheduler.active_items
  end

  def test_queue_depth_zero_initially
    assert_equal 0, @scheduler.queue_depth
  end

  def test_active_items_reflects_dispatched_items
    barrier = Mutex.new
    cv = ConditionVariable.new
    proceed = false

    item = make_item(callback: ->(_) {
      barrier.synchronize { cv.wait(barrier) until proceed }
    })

    @scheduler.enqueue(item)
    @scheduler.start

    assert wait_until { @scheduler.active_items > 0 }, "Should have active items"
    assert_equal 1, @scheduler.active_items

    barrier.synchronize { proceed = true; cv.signal }
    assert wait_until { @scheduler.active_items == 0 }, "Active items should clear after callback"
  end

  def test_queue_depth_decreases_after_dispatch
    item = make_item(callback: ->(_) {})
    @scheduler.enqueue(item)
    assert_equal 1, @scheduler.queue_depth

    @scheduler.start
    assert wait_until { @scheduler.queue_depth == 0 }, "Queue should drain after dispatch"
  end
end
