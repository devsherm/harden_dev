require_relative "test_helper"

class PipelineDiscoveryTest < PipelineTestCase
  def test_discover_with_missing_dir_sets_ready_with_error
    # @tmpdir has no app/controllers — discovery should set phase to "ready" with an error
    @pipeline.discover_controllers

    assert_equal "ready", @pipeline.phase

    state = JSON.parse(@pipeline.to_json)
    assert_equal [], state["controllers"]

    errors = state["errors"]
    assert errors.any? { |e| e["message"].include?("Controllers directory not found") },
           "Expected an error about missing controllers directory, got: #{errors}"
  end

  def test_discover_with_valid_controllers
    # Create a fake controllers directory with two controller files
    controllers_dir = File.join(@tmpdir, "app", "controllers", "blog")
    FileUtils.mkdir_p(controllers_dir)
    File.write(File.join(controllers_dir, "posts_controller.rb"), "class PostsController; end")
    File.write(File.join(controllers_dir, "comments_controller.rb"), "class CommentsController; end")
    # application_controller should be skipped
    File.write(File.join(@tmpdir, "app", "controllers", "application_controller.rb"), "class ApplicationController; end")

    @pipeline.discover_controllers

    assert_equal "ready", @pipeline.phase

    state = JSON.parse(@pipeline.to_json)
    names = state["controllers"].map { |c| c["name"] }
    assert_includes names, "posts_controller"
    assert_includes names, "comments_controller"
    refute_includes names, "application_controller"
    assert_empty state["errors"]
  end
end
