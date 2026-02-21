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

  # ── Enhance sidecar scanning tests ────────────────────────────────────────

  def setup_controller_with_enhance(ctrl_name: "posts_controller")
    controllers_dir = File.join(@tmpdir, "app", "controllers")
    FileUtils.mkdir_p(controllers_dir)
    path = File.join(controllers_dir, "#{ctrl_name}.rb")
    File.write(path, "class PostsController; end")
    enhance_dir = File.join(controllers_dir, ".enhance", ctrl_name)
    FileUtils.mkdir_p(enhance_dir)
    [path, enhance_dir]
  end

  def test_controller_without_enhance_sidecar_has_nil_resume_status
    controllers_dir = File.join(@tmpdir, "app", "controllers")
    FileUtils.mkdir_p(controllers_dir)
    File.write(File.join(controllers_dir, "posts_controller.rb"), "class PostsController; end")

    @pipeline.discover_controllers

    state = JSON.parse(@pipeline.to_json)
    ctrl = state["controllers"].find { |c| c["name"] == "posts_controller" }
    refute_nil ctrl
    assert_nil ctrl["enhance_resume_status"]
    assert_equal false, ctrl["enhance_sidecar"]
  end

  def test_controller_with_enhance_analysis_only_resumes_at_awaiting_research
    path, enhance_dir = setup_controller_with_enhance

    analysis = { "summary" => "analysis", "research_topics" => ["topic1"] }
    File.write(File.join(enhance_dir, "analysis.json"), JSON.generate(analysis))

    @pipeline.discover_controllers

    state = JSON.parse(@pipeline.to_json)
    ctrl = state["controllers"].find { |c| c["name"] == "posts_controller" }
    refute_nil ctrl
    assert_equal "e_awaiting_research", ctrl["enhance_resume_status"]
    assert_equal true, ctrl["enhance_sidecar"]
    refute_nil ctrl["enhance_analysis_at"]
  end

  def test_controller_with_pending_research_topics_resumes_at_awaiting_research
    path, enhance_dir = setup_controller_with_enhance

    File.write(File.join(enhance_dir, "analysis.json"), JSON.generate({ "research_topics" => ["t1"] }))
    research_status = [
      { "prompt" => "topic1", "status" => "completed" },
      { "prompt" => "topic2", "status" => "pending" }
    ]
    File.write(File.join(enhance_dir, "research_status.json"), JSON.generate(research_status))

    @pipeline.discover_controllers

    state = JSON.parse(@pipeline.to_json)
    ctrl = state["controllers"].find { |c| c["name"] == "posts_controller" }
    assert_equal "e_awaiting_research", ctrl["enhance_resume_status"]
  end

  def test_controller_with_all_research_complete_resumes_at_extracting
    path, enhance_dir = setup_controller_with_enhance

    File.write(File.join(enhance_dir, "analysis.json"), JSON.generate({ "research_topics" => ["t1"] }))
    research_status = [
      { "prompt" => "topic1", "status" => "completed" },
      { "prompt" => "topic2", "status" => "completed" }
    ]
    File.write(File.join(enhance_dir, "research_status.json"), JSON.generate(research_status))

    @pipeline.discover_controllers

    state = JSON.parse(@pipeline.to_json)
    ctrl = state["controllers"].find { |c| c["name"] == "posts_controller" }
    assert_equal "e_extracting", ctrl["enhance_resume_status"]
  end

  def test_controller_with_all_non_rejected_research_complete_resumes_at_extracting
    path, enhance_dir = setup_controller_with_enhance

    File.write(File.join(enhance_dir, "analysis.json"), JSON.generate({ "research_topics" => [] }))
    research_status = [
      { "prompt" => "topic1", "status" => "completed" },
      { "prompt" => "topic2", "status" => "rejected" }
    ]
    File.write(File.join(enhance_dir, "research_status.json"), JSON.generate(research_status))

    @pipeline.discover_controllers

    state = JSON.parse(@pipeline.to_json)
    ctrl = state["controllers"].find { |c| c["name"] == "posts_controller" }
    assert_equal "e_extracting", ctrl["enhance_resume_status"]
  end

  def test_controller_with_decisions_json_resumes_at_awaiting_decisions
    path, enhance_dir = setup_controller_with_enhance

    File.write(File.join(enhance_dir, "analysis.json"), JSON.generate({ "research_topics" => [] }))
    File.write(File.join(enhance_dir, "decisions.json"), JSON.generate({ "item-1" => "TODO" }))

    @pipeline.discover_controllers

    state = JSON.parse(@pipeline.to_json)
    ctrl = state["controllers"].find { |c| c["name"] == "posts_controller" }
    assert_equal "e_awaiting_decisions", ctrl["enhance_resume_status"]
  end

  def test_controller_with_batches_json_but_no_batch_progress_resumes_at_awaiting_batch_approval
    path, enhance_dir = setup_controller_with_enhance

    File.write(File.join(enhance_dir, "analysis.json"), JSON.generate({}))
    File.write(File.join(enhance_dir, "decisions.json"), JSON.generate({}))
    batches = { "batches" => [{ "id" => "batch-1", "items" => [] }] }
    File.write(File.join(enhance_dir, "batches.json"), JSON.generate(batches))

    @pipeline.discover_controllers

    state = JSON.parse(@pipeline.to_json)
    ctrl = state["controllers"].find { |c| c["name"] == "posts_controller" }
    assert_equal "e_awaiting_batch_approval", ctrl["enhance_resume_status"]
  end

  def test_controller_with_partial_batch_apply_resumes_at_applying
    path, enhance_dir = setup_controller_with_enhance

    File.write(File.join(enhance_dir, "analysis.json"), JSON.generate({}))
    batches = { "batches" => [{ "id" => "batch-1", "items" => [] }] }
    File.write(File.join(enhance_dir, "batches.json"), JSON.generate(batches))
    # No apply.json means batch not started — resumes at e_applying
    batch_dir = File.join(enhance_dir, "batches", "batch-1")
    FileUtils.mkdir_p(batch_dir)

    @pipeline.discover_controllers

    state = JSON.parse(@pipeline.to_json)
    ctrl = state["controllers"].find { |c| c["name"] == "posts_controller" }
    assert_equal "e_applying", ctrl["enhance_resume_status"]
  end

  def test_controller_with_apply_done_resumes_at_testing
    path, enhance_dir = setup_controller_with_enhance

    File.write(File.join(enhance_dir, "analysis.json"), JSON.generate({}))
    batches = { "batches" => [{ "id" => "batch-1", "items" => [] }] }
    File.write(File.join(enhance_dir, "batches.json"), JSON.generate(batches))
    batch_dir = File.join(enhance_dir, "batches", "batch-1")
    FileUtils.mkdir_p(batch_dir)
    File.write(File.join(batch_dir, "apply.json"), JSON.generate({ "status" => "ok" }))
    # No test_results.json → resumes at e_testing

    @pipeline.discover_controllers

    state = JSON.parse(@pipeline.to_json)
    ctrl = state["controllers"].find { |c| c["name"] == "posts_controller" }
    assert_equal "e_testing", ctrl["enhance_resume_status"]
  end

  def test_controller_with_tests_done_resumes_at_ci_checking
    path, enhance_dir = setup_controller_with_enhance

    File.write(File.join(enhance_dir, "analysis.json"), JSON.generate({}))
    batches = { "batches" => [{ "id" => "batch-1", "items" => [] }] }
    File.write(File.join(enhance_dir, "batches.json"), JSON.generate(batches))
    batch_dir = File.join(enhance_dir, "batches", "batch-1")
    FileUtils.mkdir_p(batch_dir)
    File.write(File.join(batch_dir, "apply.json"), JSON.generate({}))
    File.write(File.join(batch_dir, "test_results.json"), JSON.generate({}))
    # No ci_results.json → resumes at e_ci_checking

    @pipeline.discover_controllers

    state = JSON.parse(@pipeline.to_json)
    ctrl = state["controllers"].find { |c| c["name"] == "posts_controller" }
    assert_equal "e_ci_checking", ctrl["enhance_resume_status"]
  end

  def test_controller_with_all_batches_verified_resumes_at_enhance_complete
    path, enhance_dir = setup_controller_with_enhance

    File.write(File.join(enhance_dir, "analysis.json"), JSON.generate({}))
    batches = {
      "batches" => [
        { "id" => "batch-1", "items" => [] },
        { "id" => "batch-2", "items" => [] }
      ]
    }
    File.write(File.join(enhance_dir, "batches.json"), JSON.generate(batches))

    # Create verification files for both batches
    %w[batch-1 batch-2].each do |bid|
      batch_dir = File.join(enhance_dir, "batches", bid)
      FileUtils.mkdir_p(batch_dir)
      File.write(File.join(batch_dir, "verification.json"), JSON.generate({ "status" => "passed" }))
    end

    @pipeline.discover_controllers

    state = JSON.parse(@pipeline.to_json)
    ctrl = state["controllers"].find { |c| c["name"] == "posts_controller" }
    assert_equal "e_enhance_complete", ctrl["enhance_resume_status"]
  end

  def test_deferred_and_rejected_items_loaded_from_sidecar
    path, enhance_dir = setup_controller_with_enhance

    File.write(File.join(enhance_dir, "analysis.json"), JSON.generate({}))
    decisions_dir = File.join(enhance_dir, "decisions")
    FileUtils.mkdir_p(decisions_dir)

    deferred = [{ "id" => "item-1", "title" => "Deferred item", "decision" => "DEFER", "timestamp" => Time.now.iso8601 }]
    rejected = [{ "id" => "item-2", "title" => "Rejected item", "decision" => "REJECT", "timestamp" => Time.now.iso8601 }]
    File.write(File.join(decisions_dir, "deferred.json"), JSON.generate(deferred))
    File.write(File.join(decisions_dir, "rejected.json"), JSON.generate(rejected))

    @pipeline.discover_controllers

    state = JSON.parse(@pipeline.to_json)
    ctrl = state["controllers"].find { |c| c["name"] == "posts_controller" }
    refute_nil ctrl
    assert_equal 1, ctrl["deferred_items"].length
    assert_equal "item-1", ctrl["deferred_items"][0]["id"]
    assert_equal 1, ctrl["rejected_items"].length
    assert_equal "item-2", ctrl["rejected_items"][0]["id"]
  end

  def test_existing_hardening_discovery_unaffected_by_enhance_scanning
    controllers_dir = File.join(@tmpdir, "app", "controllers")
    FileUtils.mkdir_p(controllers_dir)
    path = File.join(controllers_dir, "posts_controller.rb")
    File.write(path, "class PostsController; end")

    # Write a .harden sidecar with analysis data
    harden_dir = File.join(controllers_dir, ".harden", "posts_controller")
    FileUtils.mkdir_p(harden_dir)
    analysis = { "overall_risk" => "high", "findings" => [{ "id" => "f1", "severity" => "high" }] }
    File.write(File.join(harden_dir, "analysis.json"), JSON.generate(analysis))
    File.write(File.join(harden_dir, "verification.json"), JSON.generate({ "passed" => true }))

    @pipeline.discover_controllers

    state = JSON.parse(@pipeline.to_json)
    ctrl = state["controllers"].find { |c| c["name"] == "posts_controller" }
    refute_nil ctrl
    # Hardening fields still present
    assert_equal "high", ctrl["overall_risk"]
    assert_equal true, ctrl["phases"]["analyzed"]
    assert_equal true, ctrl["phases"]["verified"]
    # Enhance fields are nil/false when no enhance sidecar
    assert_nil ctrl["enhance_resume_status"]
    assert_equal false, ctrl["enhance_sidecar"]
  end
end
