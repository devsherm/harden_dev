require_relative "test_helper"

class PipelineDiscoveryTest < PipelineTestCase
  def test_discover_with_missing_dir_sets_ready_with_error
    # @tmpdir has no app/controllers — discovery should set phase to "ready" with an error
    @pipeline.discover_controllers

    assert_equal "ready", @pipeline.phase

    state = JSON.parse(@pipeline.to_json)
    assert_equal [], state["controllers"]

    errors = state["errors"]
    assert errors.any? { |e| e["message"].include?("Discovery directory not found") },
           "Expected an error about missing discovery directory, got: #{errors}"
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

  def test_discover_with_custom_glob
    # Create view directories to discover instead of controllers
    views_dir = File.join(@tmpdir, "app", "views", "blog", "posts")
    FileUtils.mkdir_p(views_dir)
    File.write(File.join(views_dir, "index.html.erb"), "<h1>Posts</h1>")
    File.write(File.join(views_dir, "show.html.erb"), "<h1>Post</h1>")

    layouts_dir = File.join(@tmpdir, "app", "views", "layouts")
    FileUtils.mkdir_p(layouts_dir)
    File.write(File.join(layouts_dir, "application.html.erb"), "<html></html>")

    pipeline = Pipeline.new(
      rails_root: @tmpdir,
      discovery_glob: "app/views/**/*.html.erb",
      discovery_excludes: ["application.html.erb"]
    )

    pipeline.discover_controllers

    assert_equal "ready", pipeline.phase

    state = JSON.parse(pipeline.to_json)
    names = state["controllers"].map { |c| c["name"] }
    assert_includes names, "index.html.erb"
    assert_includes names, "show.html.erb"
    refute_includes names, "application.html.erb"
    assert_empty state["errors"]
  ensure
    pipeline&.shutdown(timeout: 1) rescue nil
  end

  def test_discover_with_custom_excludes
    controllers_dir = File.join(@tmpdir, "app", "controllers", "blog")
    FileUtils.mkdir_p(controllers_dir)
    File.write(File.join(controllers_dir, "posts_controller.rb"), "class PostsController; end")
    File.write(File.join(controllers_dir, "health_controller.rb"), "class HealthController; end")
    File.write(File.join(@tmpdir, "app", "controllers", "application_controller.rb"), "class ApplicationController; end")

    pipeline = Pipeline.new(
      rails_root: @tmpdir,
      discovery_excludes: ["application_controller", "health_controller"]
    )

    pipeline.discover_controllers

    state = JSON.parse(pipeline.to_json)
    names = state["controllers"].map { |c| c["name"] }
    assert_includes names, "posts_controller"
    refute_includes names, "health_controller"
    refute_includes names, "application_controller"
  ensure
    pipeline&.shutdown(timeout: 1) rescue nil
  end
end
