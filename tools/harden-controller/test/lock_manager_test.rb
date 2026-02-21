# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../pipeline/lock_manager"

class LockManagerTest < Minitest::Test
  def setup
    @lock_manager = LockManager.new
    @tmpdir = Dir.mktmpdir("lock-manager-test-")
    # Create some real files for path-based tests
    @file_a = File.join(@tmpdir, "app", "controllers", "posts_controller.rb")
    @file_b = File.join(@tmpdir, "app", "controllers", "comments_controller.rb")
    @file_c = File.join(@tmpdir, "app", "models", "post.rb")
    [@file_a, @file_b, @file_c].each do |f|
      FileUtils.mkdir_p(File.dirname(f))
      File.write(f, "# stub")
    end
  end

  def teardown
    @lock_manager.stop_reaper
    FileUtils.rm_rf(@tmpdir)
  end

  # ── try_acquire — success ─────────────────────────────────

  def test_try_acquire_returns_grant_on_success
    grant = @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])

    refute_nil grant
    assert_instance_of LockGrant, grant
    assert_equal "worker-1", grant.holder
    assert_equal [@file_a], grant.write_paths
    refute grant.released
  end

  def test_try_acquire_grant_has_uuid_id
    grant = @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])

    refute_nil grant
    assert_match(/\A[0-9a-f-]{36}\z/, grant.id)
  end

  def test_try_acquire_grant_has_timestamps
    before = Time.now
    grant = @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])
    after = Time.now

    refute_nil grant
    assert grant.acquired_at >= before
    assert grant.acquired_at <= after
    # TTL default is 30 minutes
    assert_in_delta (grant.expires_at - grant.acquired_at), 30 * 60, 2
  end

  def test_try_acquire_multiple_paths_all_or_nothing_success
    grant = @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a, @file_b])

    refute_nil grant
    assert_equal [@file_a, @file_b], grant.write_paths
  end

  def test_try_acquire_empty_paths_succeeds
    grant = @lock_manager.try_acquire(holder: "worker-1", write_paths: [])

    refute_nil grant
  end

  # ── try_acquire — conflict ────────────────────────────────

  def test_try_acquire_returns_nil_on_conflict
    @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])
    result = @lock_manager.try_acquire(holder: "worker-2", write_paths: [@file_a])

    assert_nil result
  end

  def test_try_acquire_partial_conflict_returns_nil_all_or_nothing
    @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])
    # worker-2 wants file_a (conflicting) and file_b (not conflicting)
    result = @lock_manager.try_acquire(holder: "worker-2", write_paths: [@file_a, @file_b])

    assert_nil result
    # Verify file_b was NOT locked (all-or-nothing — no partial grant)
    grant = @lock_manager.try_acquire(holder: "worker-3", write_paths: [@file_b])
    refute_nil grant, "file_b should be available since all-or-nothing prevented partial grant"
  end

  def test_try_acquire_non_overlapping_paths_both_succeed
    grant1 = @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])
    grant2 = @lock_manager.try_acquire(holder: "worker-2", write_paths: [@file_b])

    refute_nil grant1
    refute_nil grant2
  end

  def test_try_acquire_after_release_succeeds
    grant = @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])
    @lock_manager.release(grant.id)

    result = @lock_manager.try_acquire(holder: "worker-2", write_paths: [@file_a])
    refute_nil result
  end

  # ── try_acquire — directory rejection ────────────────────

  def test_try_acquire_raises_over_lock_error_for_directory
    dir_path = File.join(@tmpdir, "app", "controllers")

    err = assert_raises(OverLockError) do
      @lock_manager.try_acquire(holder: "worker-1", write_paths: [dir_path])
    end
    assert_match(/directory/i, err.message)
    assert_includes err.message, dir_path
  end

  def test_try_acquire_raises_over_lock_error_for_mixed_paths_with_directory
    dir_path = File.join(@tmpdir, "app", "controllers")

    err = assert_raises(OverLockError) do
      @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a, dir_path])
    end
    assert_match(/directory/i, err.message)
  end

  def test_try_acquire_does_not_lock_any_paths_when_directory_raises
    dir_path = File.join(@tmpdir, "app", "controllers")

    assert_raises(OverLockError) do
      @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a, dir_path])
    end

    # file_a should not be locked since the error was raised before any lock was stored
    grant = @lock_manager.try_acquire(holder: "worker-2", write_paths: [@file_a])
    refute_nil grant, "file_a should be available since OverLockError aborted before storing"
  end

  # ── acquire — blocking with timeout ──────────────────────

  def test_acquire_succeeds_immediately_when_no_conflict
    grant = @lock_manager.acquire(holder: "worker-1", write_paths: [@file_a], timeout: 1)

    refute_nil grant
    assert_equal "worker-1", grant.holder
  end

  def test_acquire_raises_lock_timeout_error_when_conflict_persists
    @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])

    err = assert_raises(LockTimeoutError) do
      @lock_manager.acquire(holder: "worker-2", write_paths: [@file_a], timeout: 0.3, interval: 0.1)
    end
    assert_match(/could not acquire lock/i, err.message)
  end

  def test_acquire_succeeds_after_release
    grant1 = @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])

    # Release the grant in a separate thread after a short delay
    release_thread = Thread.new do
      sleep 0.2
      @lock_manager.release(grant1.id)
    end

    grant2 = @lock_manager.acquire(holder: "worker-2", write_paths: [@file_a], timeout: 2, interval: 0.1)

    release_thread.join
    refute_nil grant2
  end

  def test_acquire_raises_over_lock_error_for_directory
    dir_path = File.join(@tmpdir, "app", "controllers")

    assert_raises(OverLockError) do
      @lock_manager.acquire(holder: "worker-1", write_paths: [dir_path], timeout: 1)
    end
  end

  # ── release — idempotent ──────────────────────────────────

  def test_release_marks_grant_as_released
    grant = @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])
    result = @lock_manager.release(grant.id)

    assert result
    assert grant.released
  end

  def test_release_is_idempotent
    grant = @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])
    @lock_manager.release(grant.id)

    # Second release should not raise and should return false (already released)
    result = @lock_manager.release(grant.id)
    # It's acceptable to return true or false — just must not raise
    refute_nil result
  end

  def test_release_nonexistent_grant_returns_false
    result = @lock_manager.release("nonexistent-id")
    refute result
  end

  # ── check_conflicts ───────────────────────────────────────

  def test_check_conflicts_returns_empty_when_no_active_grants
    conflicts = @lock_manager.check_conflicts([@file_a])
    assert_empty conflicts
  end

  def test_check_conflicts_returns_conflicting_grants
    grant = @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])
    conflicts = @lock_manager.check_conflicts([@file_a])

    assert_equal 1, conflicts.length
    assert_equal grant.id, conflicts.first.id
  end

  def test_check_conflicts_returns_empty_for_non_overlapping_paths
    @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])
    conflicts = @lock_manager.check_conflicts([@file_b])

    assert_empty conflicts
  end

  def test_check_conflicts_excludes_released_grants
    grant = @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])
    @lock_manager.release(grant.id)

    conflicts = @lock_manager.check_conflicts([@file_a])
    assert_empty conflicts
  end

  def test_check_conflicts_returns_multiple_grants
    grant1 = @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])
    grant2 = @lock_manager.try_acquire(holder: "worker-2", write_paths: [@file_b])

    conflicts = @lock_manager.check_conflicts([@file_a, @file_b])
    ids = conflicts.map(&:id)

    assert_includes ids, grant1.id
    assert_includes ids, grant2.id
  end

  # ── active_grants ─────────────────────────────────────────

  def test_active_grants_empty_initially
    assert_empty @lock_manager.active_grants
  end

  def test_active_grants_includes_newly_acquired_grant
    grant = @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])
    active = @lock_manager.active_grants

    assert_equal 1, active.length
    assert_equal grant.id, active.first.id
  end

  def test_active_grants_excludes_released_grants
    grant = @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])
    @lock_manager.release(grant.id)

    assert_empty @lock_manager.active_grants
  end

  def test_active_grants_excludes_expired_grants
    # Create a LockManager with very short TTL
    short_ttl_manager = LockManager.new(ttl: 0.01)
    begin
      short_ttl_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])
      sleep 0.05  # Wait for TTL to expire

      assert_empty short_ttl_manager.active_grants
    ensure
      short_ttl_manager.stop_reaper
    end
  end

  # ── grant TTL reaper ──────────────────────────────────────

  def test_reaper_thread_exists
    refute_nil @lock_manager.instance_variable_get(:@reaper_thread)
    assert @lock_manager.instance_variable_get(:@reaper_thread).alive?
  end

  def test_reaper_releases_expired_grants
    # Use a very short TTL so we can test expiry without waiting 30 minutes
    short_ttl_manager = LockManager.new(ttl: 0.01)
    begin
      short_ttl_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])

      # Wait for TTL to expire
      sleep 0.05

      # Manually trigger the reaper (since REAPER_INTERVAL is 60 seconds)
      short_ttl_manager.send(:release_expired_grants)

      grants = short_ttl_manager.instance_variable_get(:@grants)
      assert grants.values.all?(&:released), "All expired grants should be released"
    ensure
      short_ttl_manager.stop_reaper
    end
  end

  def test_reaper_keeps_renewed_grants
    short_ttl_manager = LockManager.new(ttl: 0.1)
    begin
      grant = short_ttl_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])

      # Renew before expiry
      short_ttl_manager.renew(grant.id)

      # Wait for original TTL to expire (but renewal extended it)
      sleep 0.05

      # Trigger reaper
      short_ttl_manager.send(:release_expired_grants)

      # Grant should still be active because renewal extended the TTL
      active = short_ttl_manager.active_grants
      assert_equal 1, active.length
      assert_equal grant.id, active.first.id
    ensure
      short_ttl_manager.stop_reaper
    end
  end

  def test_reaper_does_not_release_active_grants
    grant = @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])

    # Manually trigger reaper — grant is not expired, should stay active
    @lock_manager.send(:release_expired_grants)

    active = @lock_manager.active_grants
    assert_equal 1, active.length
    assert_equal grant.id, active.first.id
  end

  # ── heartbeat renewal ─────────────────────────────────────

  def test_renew_extends_expiry
    grant = @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])
    original_expires_at = grant.expires_at

    sleep 0.1
    @lock_manager.renew(grant.id)

    assert grant.expires_at > original_expires_at
  end

  def test_renew_nonexistent_grant_returns_false
    result = @lock_manager.renew("nonexistent-id")
    refute result
  end

  def test_renew_released_grant_returns_false
    grant = @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])
    @lock_manager.release(grant.id)

    result = @lock_manager.renew(grant.id)
    refute result
  end

  # ── all-or-nothing semantics ──────────────────────────────

  def test_all_or_nothing_no_partial_grant_on_conflict
    # Lock file_a
    @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])

    # Try to acquire file_a and file_c together — should fail entirely
    result = @lock_manager.try_acquire(holder: "worker-2", write_paths: [@file_a, @file_c])
    assert_nil result

    # file_c must NOT be locked (all-or-nothing)
    grant_c = @lock_manager.try_acquire(holder: "worker-3", write_paths: [@file_c])
    refute_nil grant_c, "file_c should be available since the all-or-nothing acquisition failed"
  end

  def test_all_or_nothing_both_paths_locked_on_success
    grant = @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a, @file_b])
    refute_nil grant

    # Both file_a and file_b must now be locked
    assert_nil @lock_manager.try_acquire(holder: "worker-2", write_paths: [@file_a])
    assert_nil @lock_manager.try_acquire(holder: "worker-2", write_paths: [@file_b])
  end

  # ── release_all ───────────────────────────────────────────

  def test_release_all_clears_all_grants
    @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])
    @lock_manager.try_acquire(holder: "worker-2", write_paths: [@file_b])

    @lock_manager.release_all

    assert_empty @lock_manager.active_grants
  end

  def test_release_all_allows_re_acquisition
    @lock_manager.try_acquire(holder: "worker-1", write_paths: [@file_a])
    @lock_manager.release_all

    grant = @lock_manager.try_acquire(holder: "worker-2", write_paths: [@file_a])
    refute_nil grant
  end

  # ── stop_reaper ───────────────────────────────────────────

  def test_stop_reaper_kills_reaper_thread
    reaper = @lock_manager.instance_variable_get(:@reaper_thread)
    assert reaper.alive?

    @lock_manager.stop_reaper

    refute reaper.alive?, "Reaper thread should be dead after stop_reaper"
  end
end
