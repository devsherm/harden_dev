# frozen_string_literal: true

require_relative "test_helper"

class SanitizeErrorTest < PipelineTestCase
  def test_replaces_rails_root
    msg = "File not found: #{@tmpdir}/app/controllers/blog/posts_controller.rb"
    result = @pipeline.sanitize_error(msg)
    assert_includes result, "<project>/app/controllers/blog/posts_controller.rb"
    refute_includes result, @tmpdir
  end

  def test_replaces_realpath_of_rails_root
    realpath = File.realpath(@tmpdir)
    msg = "Error loading #{realpath}/config/database.yml"
    result = @pipeline.sanitize_error(msg)
    assert_includes result, "<project>/config/database.yml"
    refute_includes result, realpath
  end

  def test_message_with_no_paths_unchanged
    msg = "Something went wrong with the analysis"
    result = @pipeline.sanitize_error(msg)
    assert_equal msg, result
  end

  def test_replaces_both_raw_and_realpath
    realpath = File.realpath(@tmpdir)
    # Construct message with both forms (possible when error messages concatenate)
    msg = "#{@tmpdir}/foo failed, see also #{realpath}/bar"
    result = @pipeline.sanitize_error(msg)
    assert_equal "<project>/foo failed, see also <project>/bar", result
  end

  def test_non_string_input_does_not_crash
    # sanitize_error rescues StandardError, so passing something that causes
    # gsub to fail should return the original input
    # Integers don't have gsub, which triggers NoMethodError (a StandardError)
    result = @pipeline.sanitize_error(42)
    assert_equal 42, result
  end
end
