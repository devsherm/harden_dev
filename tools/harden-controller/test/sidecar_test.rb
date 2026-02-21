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
    assert_match(/escapes allowed directories/i, err.message)
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
      assert_match(/escapes allowed directories/i, err.message)
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
      assert_match(/escapes allowed directories/i, err.message)
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

  # ── Custom allowed_write_paths tests ───────────────────────

  def test_safe_write_with_custom_allowed_paths_permits_views
    views_dir = File.join(@tmpdir, "app", "views", "blog")
    FileUtils.mkdir_p(views_dir)
    pipeline = Pipeline.new(rails_root: @tmpdir, allowed_write_paths: ["app/controllers", "app/views"])

    path = File.join(views_dir, "index.html.erb")
    pipeline.send(:safe_write, path, "<h1>Posts</h1>")

    assert_equal "<h1>Posts</h1>", File.read(path)
  ensure
    pipeline&.shutdown(timeout: 1) rescue nil
  end

  def test_safe_write_with_custom_allowed_paths_still_blocks_escape
    views_dir = File.join(@tmpdir, "app", "views")
    FileUtils.mkdir_p(views_dir)
    pipeline = Pipeline.new(rails_root: @tmpdir, allowed_write_paths: ["app/views"])

    err = assert_raises(RuntimeError) { pipeline.send(:safe_write, File.join(@controllers_dir, "evil.rb"), "evil") }
    assert_match(/escapes allowed directories/i, err.message)
  ensure
    pipeline&.shutdown(timeout: 1) rescue nil
  end

  def test_write_sidecar_with_custom_allowed_paths_permits_views
    views_dir = File.join(@tmpdir, "app", "views", "blog", "posts")
    FileUtils.mkdir_p(views_dir)
    pipeline = Pipeline.new(rails_root: @tmpdir, allowed_write_paths: ["app/views"])

    target = File.join(views_dir, "index.html.erb")
    File.write(target, "<h1>Posts</h1>")
    pipeline.send(:ensure_sidecar_dir, target)
    pipeline.send(:write_sidecar, target, "analysis.json", '{"ok": true}')

    sidecar = File.join(views_dir, ".harden", "index.html.erb", "analysis.json")
    assert File.exist?(sidecar), "Expected sidecar file at #{sidecar}"
  ensure
    pipeline&.shutdown(timeout: 1) rescue nil
  end

  # ── Custom sidecar_dir tests ───────────────────────────────

  def test_sidecar_path_uses_custom_dir
    pipeline = Pipeline.new(rails_root: @tmpdir, sidecar_dir: ".review")
    ctrl_path = File.join(@controllers_dir, "posts_controller.rb")

    result = pipeline.send(:sidecar_path, ctrl_path, "analysis.json")
    assert_includes result, "/.review/"
    refute_includes result, "/.harden/"
  ensure
    pipeline&.shutdown(timeout: 1) rescue nil
  end

  def test_ensure_sidecar_dir_creates_custom_dir
    pipeline = Pipeline.new(rails_root: @tmpdir, sidecar_dir: ".review")
    ctrl_path = File.join(@controllers_dir, "posts_controller.rb")
    File.write(ctrl_path, "# stub")

    pipeline.send(:ensure_sidecar_dir, ctrl_path)

    expected_dir = File.join(@controllers_dir, ".review", "posts_controller")
    assert Dir.exist?(expected_dir), "Expected directory #{expected_dir} to exist"
  ensure
    pipeline&.shutdown(timeout: 1) rescue nil
  end

  # ── staging_path tests ─────────────────────────────────────

  def test_staging_path_returns_staging_subdir
    ctrl_path = File.join(@controllers_dir, "posts_controller.rb")
    result = @pipeline.send(:staging_path, ctrl_path)
    expected = File.join(@controllers_dir, ".harden", "posts_controller", "staging")
    assert_equal expected, result
  end

  def test_staging_path_with_custom_sidecar_dir
    pipeline = Pipeline.new(rails_root: @tmpdir, sidecar_dir: ".review")
    ctrl_path = File.join(@controllers_dir, "posts_controller.rb")
    result = pipeline.send(:staging_path, ctrl_path)
    assert_includes result, "/.review/"
    assert result.end_with?("/staging")
  ensure
    pipeline&.shutdown(timeout: 1) rescue nil
  end

  # ── copy_from_staging tests ────────────────────────────────

  def test_copy_from_staging_copies_files_to_real_paths
    ctrl_path = File.join(@controllers_dir, "posts_controller.rb")
    File.write(ctrl_path, "# original")

    staging_dir = Dir.mktmpdir("staging-")
    begin
      staged_file_dir = File.join(staging_dir, "app", "controllers", "blog")
      FileUtils.mkdir_p(staged_file_dir)
      File.write(File.join(staged_file_dir, "posts_controller.rb"), "# hardened")

      @pipeline.send(:copy_from_staging, staging_dir)

      assert_equal "# hardened", File.read(ctrl_path)
    ensure
      FileUtils.rm_rf(staging_dir)
    end
  end

  def test_copy_from_staging_copies_multiple_files
    ctrl_path = File.join(@controllers_dir, "posts_controller.rb")
    comments_path = File.join(@controllers_dir, "comments_controller.rb")
    File.write(ctrl_path, "# original posts")
    File.write(comments_path, "# original comments")

    staging_dir = Dir.mktmpdir("staging-")
    begin
      staged_dir = File.join(staging_dir, "app", "controllers", "blog")
      FileUtils.mkdir_p(staged_dir)
      File.write(File.join(staged_dir, "posts_controller.rb"), "# hardened posts")
      File.write(File.join(staged_dir, "comments_controller.rb"), "# hardened comments")

      @pipeline.send(:copy_from_staging, staging_dir)

      assert_equal "# hardened posts", File.read(ctrl_path)
      assert_equal "# hardened comments", File.read(comments_path)
    ensure
      FileUtils.rm_rf(staging_dir)
    end
  end

  def test_copy_from_staging_empty_dir_is_noop
    ctrl_path = File.join(@controllers_dir, "posts_controller.rb")
    File.write(ctrl_path, "# original")

    staging_dir = Dir.mktmpdir("staging-")
    begin
      @pipeline.send(:copy_from_staging, staging_dir)

      assert_equal "# original", File.read(ctrl_path)
    ensure
      FileUtils.rm_rf(staging_dir)
    end
  end

  def test_copy_from_staging_rejects_paths_outside_allowed
    staging_dir = Dir.mktmpdir("staging-")
    begin
      # Stage a file that resolves outside app/controllers
      staged_dir = File.join(staging_dir, "config")
      FileUtils.mkdir_p(staged_dir)
      File.write(File.join(staged_dir, "secrets.yml"), "secret: value")

      # Also create the target directory so realpath can resolve it
      config_dir = File.join(@tmpdir, "config")
      FileUtils.mkdir_p(config_dir)

      err = assert_raises(RuntimeError) do
        @pipeline.send(:copy_from_staging, staging_dir)
      end
      assert_match(/escapes allowed directories/i, err.message)
    ensure
      FileUtils.rm_rf(staging_dir)
    end
  end

  # ── Custom test_path_resolver tests ────────────────────────

  def test_custom_test_path_resolver
    custom_resolver = ->(target_path, rails_root) {
      File.join(rails_root, "spec", File.basename(target_path).sub(/\.rb\z/, "_spec.rb"))
    }
    pipeline = Pipeline.new(rails_root: @tmpdir, test_path_resolver: custom_resolver)

    spec_path = File.join(@tmpdir, "spec", "posts_controller_spec.rb")
    FileUtils.mkdir_p(File.dirname(spec_path))
    File.write(spec_path, "# spec")

    ctrl_path = File.join(@controllers_dir, "posts_controller.rb")
    result = pipeline.send(:derive_test_path, ctrl_path)
    assert_equal spec_path, result
  ensure
    pipeline&.shutdown(timeout: 1) rescue nil
  end
end
