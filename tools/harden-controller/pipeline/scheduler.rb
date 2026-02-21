# frozen_string_literal: true

require "securerandom"

# WorkItem represents a unit of work to be dispatched by the Scheduler.
WorkItem = Struct.new(
  :id,           # String (SecureRandom.uuid)
  :workflow,     # String (controller name or workflow identifier)
  :phase,        # Symbol (e.g. :e_applying, :e_extracting, :e_analyzing)
  :lock_request, # LockRequest (paths to lock before dispatch)
  :status,       # Symbol (:queued, :dispatching, :active, :done)
  :queued_at,    # Time
  :dispatched_at, # Time or nil
  :grant_id,     # String or nil (LockGrant id assigned on dispatch)
  :callback,     # Proc — called with the grant_id when dispatched
  keyword_init: true
) do
  def initialize(id: SecureRandom.uuid, workflow:, phase:,
                 lock_request: LockRequest.new(write_paths: []),
                 status: :queued, queued_at: Time.now,
                 dispatched_at: nil, grant_id: nil, callback:)
    super
  end
end

# Scheduler dispatches WorkItems when a Claude slot is available and locks can
# be acquired. It runs a background dispatch loop that polls every 0.5 seconds.
#
# Priority ordering (lower number = higher priority):
#   e_applying → 0, e_extracting → 1, e_analyzing → 2, others → 3
#
# Starvation prevention: items queued >10 minutes get effective priority -1.
#
# Thread-safe — all queue and active-items state is guarded by @mutex.
class Scheduler
  PHASE_PRIORITY = {
    e_applying:   0,
    e_extracting: 1,
    e_analyzing:  2
  }.freeze
  DEFAULT_PRIORITY = 3
  STARVATION_THRESHOLD = 600  # 10 minutes in seconds
  DISPATCH_INTERVAL = 0.5     # seconds between dispatch loop iterations

  # Constructs a Scheduler.
  #
  # @param lock_manager [LockManager] used to call try_acquire before dispatch
  # @param slot_available_fn [Proc] callable returning true when a Claude slot
  #   is available (e.g. -> { @claude_active < MAX_CLAUDE_CONCURRENCY })
  # @param safe_thread_fn [Proc] callable that takes a block and runs it in a
  #   managed thread (mirrors Pipeline#safe_thread semantics)
  def initialize(lock_manager:, slot_available_fn:, safe_thread_fn:)
    @lock_manager = lock_manager
    @slot_available_fn = slot_available_fn
    @safe_thread_fn = safe_thread_fn

    @mutex = Mutex.new
    @queue = []          # Array<WorkItem>
    @active = {}         # id → WorkItem (dispatched items)

    @shutdown = false
    @dispatch_thread = nil
  end

  # Add a WorkItem to the dispatch queue.
  # Returns the enqueued WorkItem.
  def enqueue(work_item)
    @mutex.synchronize do
      @queue << work_item
    end
    work_item
  end

  # Start the background dispatch loop thread.
  # Idempotent — safe to call multiple times (only one loop runs).
  def start
    @mutex.synchronize do
      return if @dispatch_thread&.alive?
      @shutdown = false
      @dispatch_thread = Thread.new { dispatch_loop }
      @dispatch_thread.name = "scheduler-dispatch"
    end
    self
  end

  # Stop the dispatch loop and wait for all active items to finish.
  # After stop, no new items will be dispatched.
  def stop
    @mutex.synchronize { @shutdown = true }
    @dispatch_thread&.join(10)
  end

  # Returns the number of items currently in the queue (not yet dispatched).
  def queue_depth
    @mutex.synchronize { @queue.length }
  end

  # Returns the number of items currently being dispatched / active.
  def active_items
    @mutex.synchronize { @active.length }
  end

  # Returns a snapshot of all currently active WorkItems.
  def active_work_items
    @mutex.synchronize { @active.values.dup }
  end

  # Returns a snapshot of all queued WorkItems (not yet dispatched).
  def queued_items
    @mutex.synchronize { @queue.dup }
  end

  private

  # Map a phase symbol to its numeric priority (lower = higher priority).
  # Items waiting >STARVATION_THRESHOLD seconds get priority -1 (highest).
  def effective_priority(item)
    if Time.now - item.queued_at > STARVATION_THRESHOLD
      -1
    else
      PHASE_PRIORITY.fetch(item.phase, DEFAULT_PRIORITY)
    end
  end

  # Main dispatch loop — runs until @shutdown is true and the active set drains.
  def dispatch_loop
    until shutdown_complete?
      sleep DISPATCH_INTERVAL
      dispatch_pending
    end
  rescue => e
    warn "Scheduler dispatch loop error: #{e.class}: #{e.message}"
  end

  # Returns true when shutdown is requested and all active items are done.
  def shutdown_complete?
    @mutex.synchronize { @shutdown && @active.empty? && @queue.empty? }
  end

  # Attempt to dispatch one or more queued items.
  def dispatch_pending
    # Snapshot the queue sorted by priority (stable sort preserves queued_at order)
    candidates = @mutex.synchronize do
      return if @shutdown  # no new dispatches after shutdown requested
      @queue.sort_by { |item| [effective_priority(item), item.queued_at] }
    end

    candidates.each do |item|
      # Check if a Claude slot is available
      break unless @slot_available_fn.call

      # Try to acquire locks for this item (if it needs any)
      grant = attempt_lock(item)
      next if grant == :conflict  # skip this item, try next

      dispatch_item(item, grant)
    end
  end

  # Attempt to acquire a lock for the item.
  # Returns a LockGrant (or nil if no paths), or :conflict if locked.
  def attempt_lock(item)
    paths = item.lock_request&.write_paths || []
    return nil if paths.empty?

    grant = @lock_manager.try_acquire(holder: item.id, write_paths: paths)
    grant.nil? ? :conflict : grant
  rescue OverLockError
    # Directory paths not allowed — skip this item permanently
    @mutex.synchronize { @queue.delete(item) }
    nil
  end

  # Move item from queue to active set and run its callback in a managed thread.
  def dispatch_item(item, grant)
    @mutex.synchronize do
      # Check again under mutex that item is still in queue (may have been removed)
      return unless @queue.delete(item)

      item.status = :dispatching
      item.dispatched_at = Time.now
      item.grant_id = grant&.id
      @active[item.id] = item
    end

    @safe_thread_fn.call do
      begin
        item.status = :active
        item.callback.call(item.grant_id)
      ensure
        @lock_manager.release(item.grant_id) if item.grant_id
        @mutex.synchronize do
          item.status = :done
          @active.delete(item.id)
        end
      end
    end
  end
end
