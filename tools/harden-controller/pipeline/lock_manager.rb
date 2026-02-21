# frozen_string_literal: true

require "securerandom"

# Custom error classes for LockManager
class OverLockError < StandardError; end
class LockTimeoutError < StandardError; end
class LockViolationError < StandardError; end

# Represents a lock request (set of write paths to lock)
LockRequest = Struct.new(:write_paths, keyword_init: true) do
  def initialize(write_paths: [])
    super
  end
end

# Represents an active lock grant
LockGrant = Struct.new(:id, :holder, :write_paths, :acquired_at, :expires_at, :released, keyword_init: true) do
  def initialize(id: SecureRandom.uuid, holder:, write_paths:,
                 acquired_at: Time.now, expires_at: Time.now + (30 * 60), released: false)
    super
  end

  def active?
    !released && expires_at > Time.now
  end
end

# LockManager tracks active grants and resolves conflicts for enhance mode.
# Thread-safe — all state guarded by a single Mutex.
# Only used by enhance mode; hardening mode bypasses locking entirely.
#
# Lock semantics:
# - Write-only locks on individual files (no directory locks, no read locks)
# - Conflict: two write locks on overlapping paths are blocked
# - Overlap check: exact file path match
# - All-or-nothing acquisition: all paths granted or none
# - Grant TTL: 30 minutes by default, renewed on heartbeat
# - Background reaper releases expired grants
class LockManager
  DEFAULT_TTL = 30 * 60  # 30 minutes in seconds
  REAPER_INTERVAL = 60   # seconds between reaper runs

  def initialize(ttl: DEFAULT_TTL)
    @ttl = ttl
    @grants = {}   # keyed by grant id
    @mutex = Mutex.new
    @reaper_thread = Thread.new { reaper_loop }
    @reaper_thread.name = "lock-manager-reaper"
  end

  # Attempt to acquire write locks for all write_paths.
  # Returns a LockGrant on success, nil on conflict.
  # Raises OverLockError if any path is a directory.
  # Raises OverLockError if write_paths contains any directory path.
  def try_acquire(holder:, write_paths:)
    write_paths = Array(write_paths)

    # Check for directory paths — reject with OverLockError
    write_paths.each do |path|
      raise OverLockError, "Directory paths cannot be locked: #{path}" if File.directory?(path)
    end

    @mutex.synchronize do
      # Check for conflicts with all active grants
      active = active_grants_unlocked

      conflicting = write_paths.any? do |path|
        active.any? { |grant| grant.write_paths.include?(path) }
      end

      return nil if conflicting

      # No conflicts — create and store the grant
      grant = LockGrant.new(
        holder: holder,
        write_paths: write_paths,
        acquired_at: Time.now,
        expires_at: Time.now + @ttl
      )
      @grants[grant.id] = grant
      grant
    end
  end

  # Blocking acquire — loops calling try_acquire with a sleep interval.
  # Raises LockTimeoutError if the timeout expires without acquiring.
  # Raises OverLockError immediately if any path is a directory.
  def acquire(holder:, write_paths:, timeout: 30, interval: 0.5)
    deadline = Time.now + timeout

    loop do
      grant = try_acquire(holder: holder, write_paths: write_paths)
      return grant if grant

      raise LockTimeoutError, "Could not acquire lock for #{write_paths.inspect} within #{timeout}s" if Time.now >= deadline

      sleep interval
    end
  end

  # Release a grant by id. Idempotent — safe to call multiple times.
  # Returns true if grant was found and released, false otherwise.
  def release(grant_id)
    @mutex.synchronize do
      grant = @grants[grant_id]
      return false unless grant
      grant.released = true
      true
    end
  end

  # Renew a grant's TTL. Updates expires_at to now + ttl.
  # Returns true if grant was found and renewed, false otherwise.
  def renew(grant_id)
    @mutex.synchronize do
      grant = @grants[grant_id]
      return false unless grant || grant&.released
      return false if grant.released
      grant.expires_at = Time.now + @ttl
      true
    end
  end

  # Check for conflicts between a proposed set of write_paths and active grants.
  # Returns an array of conflicting grants.
  def check_conflicts(write_paths)
    write_paths = Array(write_paths)
    @mutex.synchronize do
      active_grants_unlocked.select do |grant|
        write_paths.any? { |path| grant.write_paths.include?(path) }
      end
    end
  end

  # Returns an array of all currently active (non-released, non-expired) grants.
  def active_grants
    @mutex.synchronize { active_grants_unlocked }
  end

  # Find a grant by id. Returns the grant or nil.
  def find_grant(grant_id)
    @mutex.synchronize { @grants[grant_id] }
  end

  # Release all active grants (used by Pipeline#reset!).
  def release_all
    @mutex.synchronize do
      @grants.each_value { |grant| grant.released = true }
    end
  end

  # Stop the reaper thread (for clean test teardown).
  def stop_reaper
    @reaper_thread.kill
    @reaper_thread.join(2)
  end

  private

  # Returns active grants without acquiring the mutex (caller must hold it).
  def active_grants_unlocked
    @grants.values.select(&:active?)
  end

  # Release all expired grants.
  def release_expired_grants
    @mutex.synchronize do
      @grants.each_value do |grant|
        grant.released = true if !grant.released && grant.expires_at < Time.now
      end
    end
  end

  def reaper_loop
    loop do
      sleep REAPER_INTERVAL
      release_expired_grants
    end
  rescue => e
    # Reaper dying silently is preferable to crashing the process.
    # Grants will just accumulate until next manual release or reset.
    warn "LockManager reaper error: #{e.class}: #{e.message}"
  end
end
