require_relative "test_helper"

class PipelineSpawnTest < PipelineTestCase
  def test_spawn_success_returns_output_and_true
    output, success = @pipeline.send(:spawn_with_timeout, "echo", "hello", timeout: 5)
    assert success
    assert_match(/hello/, output)
  end

  def test_spawn_failure_returns_output_and_false
    output, success = @pipeline.send(:spawn_with_timeout, "false", timeout: 5)
    refute success
  end

  def test_spawn_timeout_raises
    assert_raises(RuntimeError) do
      @pipeline.send(:spawn_with_timeout, "sleep", "30", timeout: 0.3)
    end
  end

  def test_spawn_nonexistent_command_does_not_leak_fds
    assert_no_fd_leak(tolerance: 0) do
      5.times do
        @pipeline.send(:spawn_with_timeout, "/usr/bin/nonexistent_binary_xyz", timeout: 5) rescue nil
      end
    end
  end

  def test_spawn_nonexistent_command_closes_both_pipe_ends
    ios_before = ObjectSpace.each_object(IO).reject(&:closed?).to_set
    @pipeline.send(:spawn_with_timeout, "/usr/bin/nonexistent_binary_xyz", timeout: 5) rescue nil
    GC.start
    ios_after = ObjectSpace.each_object(IO).reject(&:closed?).to_set
    leaked = ios_after - ios_before
    assert_empty leaked, "Leaked IOs after failed spawn: #{leaked.inspect}"
  end

  def test_spawn_success_does_not_leak_fds
    assert_no_fd_leak(tolerance: 0) do
      5.times do
        @pipeline.send(:spawn_with_timeout, "echo", "hello", timeout: 5)
      end
    end
  end

  def test_spawn_timeout_does_not_leak_fds
    assert_no_fd_leak(tolerance: 0) do
      3.times do
        @pipeline.send(:spawn_with_timeout, "sleep", "30", timeout: 0.3) rescue nil
      end
    end
  end
end
