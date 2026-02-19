require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../pipeline"

module FDCounter
  def fd_count
    GC.start
    Dir.children("/proc/self/fd").count
  end

  def assert_no_fd_leak(tolerance: 0)
    before = fd_count
    yield
    after = fd_count
    assert after <= before + tolerance,
           "FD leak detected: before=#{before}, after=#{after}, tolerance=#{tolerance}"
  end
end

class PipelineTestCase < Minitest::Test
  include FDCounter

  def setup
    @tmpdir = Dir.mktmpdir("harden-test-")
    @pipeline = Pipeline.new(rails_root: @tmpdir)
  end

  def teardown
    @pipeline.shutdown(timeout: 2) rescue nil
    FileUtils.rm_rf(@tmpdir)
  end
end
