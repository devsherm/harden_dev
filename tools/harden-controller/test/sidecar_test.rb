# frozen_string_literal: true

require_relative "test_helper"

class SidecarTest < PipelineTestCase
  def setup
    super
    @controllers_dir = File.join(@tmpdir, "app", "controllers", "blog")
    FileUtils.mkdir_p(@controllers_dir)
  end

  # ── safe_write tests ──────────────────────────────────────

  def test_safe_write_within_controllers_succeeds
    path = File.join(@controllers_dir, "posts_controller.rb")
    File.write(path, "# original")  # create so directory exists for realpath

    @pipeline.send(:safe_write, path, "# hardened")

    assert_equal "# hardened", File.read(path)
  end

  def test_safe_write_path_traversal_raises
    # Try to escape to config/ via ../ — directory must exist for realpath resolution
    escape_dir = File.join(@tmpdir, "config")
    FileUtils.mkdir_p(escape_dir)
    # Build path that resolves outside controllers/ but within a real directory
    path = File.join(escape_dir, "secrets.yml")

    err = assert_raises(RuntimeError) { @pipeline.send(:safe_write, path, "secrets") }
    assert_match(/escapes controllers directory/i, err.message)
    refute File.exist?(path)
  end

  def test_safe_write_absolute_escape_raises
    # /etc/passwd style absolute path — realpath won't start with controllers dir
    # Create a temp file we can resolve
    outside_dir = Dir.mktmpdir("outside-")
    begin
      path = File.join(outside_dir, "evil.rb")
      FileUtils.touch(path)  # file must exist for dirname realpath

      err = assert_raises(RuntimeError) { @pipeline.send(:safe_write, path, "evil") }
      assert_match(/escapes controllers directory/i, err.message)
    ensure
      FileUtils.rm_rf(outside_dir)
    end
  end

  def test_safe_write_symlink_escape_raises
    # Create a symlink inside controllers/ that points outside
    outside_dir = Dir.mktmpdir("symlink-target-")
    begin
      link_path = File.join(@controllers_dir, "sneaky")
      File.symlink(outside_dir, link_path)

      target_file = File.join(link_path, "evil.rb")

      err = assert_raises(RuntimeError) { @pipeline.send(:safe_write, target_file, "evil") }
      assert_match(/escapes controllers directory/i, err.message)
    ensure
      FileUtils.rm_rf(outside_dir)
    end
  end

  def test_safe_write_nested_controller_succeeds
    nested_dir = File.join(@controllers_dir, "admin")
    FileUtils.mkdir_p(nested_dir)
    path = File.join(nested_dir, "users_controller.rb")

    @pipeline.send(:safe_write, path, "# admin controller")

    assert_equal "# admin controller", File.read(path)
  end

  # ── derive_test_path tests ────────────────────────────────

  def test_derive_test_path_standard
    ctrl_path = File.join(@tmpdir, "app", "controllers", "blog", "posts_controller.rb")
    test_path = File.join(@tmpdir, "test", "controllers", "blog", "posts_controller_test.rb")
    FileUtils.mkdir_p(File.dirname(test_path))
    File.write(test_path, "# test")

    result = @pipeline.send(:derive_test_path, ctrl_path)
    assert_equal test_path, result
  end

  def test_derive_test_path_nested_namespace
    ctrl_path = File.join(@tmpdir, "app", "controllers", "blog", "admin", "settings_controller.rb")
    test_path = File.join(@tmpdir, "test", "controllers", "blog", "admin", "settings_controller_test.rb")
    FileUtils.mkdir_p(File.dirname(test_path))
    File.write(test_path, "# test")

    result = @pipeline.send(:derive_test_path, ctrl_path)
    assert_equal test_path, result
  end

  def test_derive_test_path_missing_test_file_returns_nil
    ctrl_path = File.join(@tmpdir, "app", "controllers", "blog", "posts_controller.rb")
    # Don't create the test file

    result = @pipeline.send(:derive_test_path, ctrl_path)
    assert_nil result
  end

  def test_derive_test_path_preserves_directory_structure
    ctrl_path = File.join(@tmpdir, "app", "controllers", "api", "v1", "tokens_controller.rb")
    test_path = File.join(@tmpdir, "test", "controllers", "api", "v1", "tokens_controller_test.rb")
    FileUtils.mkdir_p(File.dirname(test_path))
    File.write(test_path, "# test")

    result = @pipeline.send(:derive_test_path, ctrl_path)
    assert_equal test_path, result
  end
end
