# frozen_string_literal: true

require_relative "orchestration_test_helper"

# Tests for the parameterization kwargs added to shared phases:
#   analysis_key:, sidecar_dir:, staging_subdir:, sidecar_output_dir:
#
# These kwargs enable enhance mode to direct shared phases to read from
# different workflow fields and write sidecar output to batch directories.
class SharedPhasesKwargsTest < OrchestrationTestCase
  def setup
    super
    @ctrl_name = "posts_controller"
    @ctrl_path = create_controller(@ctrl_name)
    @test_path = create_test_file(@ctrl_name)
    seed_controller(@ctrl_name)
  end

  # ── analysis_key ────────────────────────────────────────────

  def test_shared_verify_reads_custom_analysis_key
    e_analysis = analysis_fixture.merge("overall_risk" => "custom_marker")
    seed_workflow(@ctrl_name,
                  status: "h_ci_passed",
                  e_analysis: e_analysis,
                  original_source: CONTROLLER_SOURCE)
    stub_claude_call(verification_fixture)

    @pipeline.send(:shared_verify, @ctrl_name,
                   guard_status: "h_ci_passed",
                   verifying_status: "h_verifying",
                   verified_status: "h_complete",
                   verify_prompt_fn: method(:capture_verify_prompt),
                   prompt_key: :test_verify,
                   analysis_key: :e_analysis)

    assert_includes @captured_analysis_json, "custom_marker"
  end

  def test_shared_apply_reads_custom_analysis_key
    e_analysis = analysis_fixture.merge("overall_risk" => "apply_marker")
    seed_workflow(@ctrl_name,
                  status: "h_awaiting_decisions",
                  e_analysis: e_analysis,
                  decision: decision_fixture(action: "approve"))
    stub_claude_call(hardened_fixture)
    stub_copy_from_staging(@ctrl_path)

    @pipeline.send(:shared_apply, @ctrl_name,
                   apply_prompt_fn: method(:capture_apply_prompt),
                   applied_status: "h_hardened",
                   applying_status: "h_hardening",
                   skipped_status: "h_skipped",
                   sidecar_dir: @pipeline.instance_variable_get(:@sidecar_dir),
                   prompt_key: :test_apply,
                   sidecar_file: "hardened.json",
                   analysis_key: :e_analysis)

    assert_includes @captured_analysis_json, "apply_marker"
  end

  def test_shared_test_reads_custom_analysis_key
    e_analysis = analysis_fixture.merge("overall_risk" => "test_marker")
    seed_workflow(@ctrl_name,
                  status: "h_hardened",
                  e_analysis: e_analysis)
    # Fail first run so it enters the fix loop where analysis is read
    stub_spawn_sequence([["FAIL", false], ["OK", true]])
    stub_claude_call(fix_tests_fixture)
    stub_copy_from_staging(@ctrl_path)

    @pipeline.send(:shared_test, @ctrl_name,
                   guard_status: "h_hardened",
                   testing_status: "h_testing",
                   fixing_status: "h_fixing_tests",
                   tested_status: "h_tested",
                   tests_failed_status: "h_tests_failed",
                   fix_prompt_fn: method(:capture_fix_prompt),
                   prompt_key: :test_fix,
                   analysis_key: :e_analysis)

    assert_includes @captured_analysis_json, "test_marker"
  end

  def test_shared_ci_check_reads_custom_analysis_key
    e_analysis = analysis_fixture.merge("overall_risk" => "ci_marker")
    seed_workflow(@ctrl_name,
                  status: "h_tested",
                  e_analysis: e_analysis)
    stub_ci_checks_sequence([failing_ci_results, passing_ci_results])
    stub_claude_call(fix_ci_fixture)
    stub_copy_from_staging(@ctrl_path)

    @pipeline.send(:shared_ci_check, @ctrl_name,
                   guard_status: "h_tested",
                   ci_checking_status: "h_ci_checking",
                   fixing_status: "h_fixing_ci",
                   ci_passed_status: "h_ci_passed",
                   ci_failed_status: "h_ci_failed",
                   fix_prompt_fn: method(:capture_ci_fix_prompt),
                   prompt_key: :test_fix_ci,
                   analysis_key: :e_analysis)

    assert_includes @captured_analysis_json, "ci_marker"
  end

  # ── sidecar_output_dir ──────────────────────────────────────

  def test_shared_verify_writes_to_sidecar_output_dir
    output_dir = File.join(@tmpdir, "custom_sidecar", "batches", "b1")
    seed_workflow(@ctrl_name,
                  status: "h_ci_passed",
                  analysis: analysis_fixture,
                  original_source: CONTROLLER_SOURCE)
    stub_claude_call(verification_fixture)

    @pipeline.send(:shared_verify, @ctrl_name,
                   guard_status: "h_ci_passed",
                   verifying_status: "h_verifying",
                   verified_status: "h_complete",
                   verify_prompt_fn: method(:passthrough_verify_prompt),
                   prompt_key: :test_verify,
                   sidecar_output_dir: output_dir)

    # Sidecar written to custom dir
    custom_path = File.join(output_dir, "verification.json")
    assert File.exist?(custom_path), "Expected verification.json in custom sidecar dir"
    parsed = JSON.parse(File.read(custom_path))
    assert_equal "accept", parsed["recommendation"]

    # Default sidecar location should NOT have the file
    refute sidecar_exists?(@ctrl_path, "verification.json")
  end

  def test_shared_apply_writes_to_sidecar_output_dir
    output_dir = File.join(@tmpdir, "custom_sidecar", "batches", "b1")
    seed_workflow(@ctrl_name,
                  status: "h_awaiting_decisions",
                  analysis: analysis_fixture,
                  decision: decision_fixture(action: "approve"))
    stub_claude_call(hardened_fixture)
    stub_copy_from_staging(@ctrl_path)

    @pipeline.send(:shared_apply, @ctrl_name,
                   apply_prompt_fn: method(:passthrough_apply_prompt),
                   applied_status: "h_hardened",
                   applying_status: "h_hardening",
                   skipped_status: "h_skipped",
                   sidecar_dir: @pipeline.instance_variable_get(:@sidecar_dir),
                   prompt_key: :test_apply,
                   sidecar_file: "apply.json",
                   sidecar_output_dir: output_dir)

    # Sidecar written to custom dir
    custom_path = File.join(output_dir, "apply.json")
    assert File.exist?(custom_path), "Expected apply.json in custom sidecar dir"

    # Staging dir was under custom dir
    assert Dir.exist?(File.join(output_dir, "staging")),
           "Expected staging dir under custom sidecar dir"
  end

  def test_shared_test_writes_to_sidecar_output_dir
    output_dir = File.join(@tmpdir, "custom_sidecar", "batches", "b1")
    seed_workflow(@ctrl_name,
                  status: "h_hardened",
                  analysis: analysis_fixture)
    stub_spawn(output: "OK", success: true)

    @pipeline.send(:shared_test, @ctrl_name,
                   guard_status: "h_hardened",
                   testing_status: "h_testing",
                   fixing_status: "h_fixing_tests",
                   tested_status: "h_tested",
                   tests_failed_status: "h_tests_failed",
                   fix_prompt_fn: method(:passthrough_fix_prompt),
                   prompt_key: :test_fix,
                   sidecar_output_dir: output_dir)

    custom_path = File.join(output_dir, "test_results.json")
    assert File.exist?(custom_path), "Expected test_results.json in custom sidecar dir"
    refute sidecar_exists?(@ctrl_path, "test_results.json")
  end

  def test_shared_ci_check_writes_to_sidecar_output_dir
    output_dir = File.join(@tmpdir, "custom_sidecar", "batches", "b1")
    seed_workflow(@ctrl_name,
                  status: "h_tested",
                  analysis: analysis_fixture)
    stub_ci_checks_pass

    @pipeline.send(:shared_ci_check, @ctrl_name,
                   guard_status: "h_tested",
                   ci_checking_status: "h_ci_checking",
                   fixing_status: "h_fixing_ci",
                   ci_passed_status: "h_ci_passed",
                   ci_failed_status: "h_ci_failed",
                   fix_prompt_fn: method(:passthrough_ci_fix_prompt),
                   prompt_key: :test_fix_ci,
                   sidecar_output_dir: output_dir)

    custom_path = File.join(output_dir, "ci_results.json")
    assert File.exist?(custom_path), "Expected ci_results.json in custom sidecar dir"
    refute sidecar_exists?(@ctrl_path, "ci_results.json")
  end

  # ── sidecar_dir + staging_subdir ────────────────────────────

  def test_shared_test_uses_custom_sidecar_dir_for_staging
    seed_workflow(@ctrl_name,
                  status: "h_hardened",
                  analysis: analysis_fixture)
    # Fail first so it enters fix loop and creates staging dir
    stub_spawn_sequence([["FAIL", false], ["OK", true]])
    stub_claude_call(fix_tests_fixture)
    stub_copy_from_staging(@ctrl_path)

    @pipeline.send(:shared_test, @ctrl_name,
                   guard_status: "h_hardened",
                   testing_status: "h_testing",
                   fixing_status: "h_fixing_tests",
                   tested_status: "h_tested",
                   tests_failed_status: "h_tests_failed",
                   fix_prompt_fn: method(:passthrough_fix_prompt),
                   prompt_key: :test_fix,
                   sidecar_dir: ".custom",
                   staging_subdir: "custom_staging")

    # Staging directory should have been created under .custom
    expected_stg = File.join(File.dirname(@ctrl_path), ".custom", @ctrl_name, "custom_staging")
    assert Dir.exist?(expected_stg), "Expected staging dir at #{expected_stg}"
  end

  def test_shared_ci_check_uses_custom_sidecar_dir_for_staging
    seed_workflow(@ctrl_name,
                  status: "h_tested",
                  analysis: analysis_fixture)
    stub_ci_checks_sequence([failing_ci_results, passing_ci_results])
    stub_claude_call(fix_ci_fixture)
    stub_copy_from_staging(@ctrl_path)

    @pipeline.send(:shared_ci_check, @ctrl_name,
                   guard_status: "h_tested",
                   ci_checking_status: "h_ci_checking",
                   fixing_status: "h_fixing_ci",
                   ci_passed_status: "h_ci_passed",
                   ci_failed_status: "h_ci_failed",
                   fix_prompt_fn: method(:passthrough_ci_fix_prompt),
                   prompt_key: :test_fix_ci,
                   sidecar_dir: ".custom",
                   staging_subdir: "custom_staging")

    expected_stg = File.join(File.dirname(@ctrl_path), ".custom", @ctrl_name, "custom_staging")
    assert Dir.exist?(expected_stg), "Expected staging dir at #{expected_stg}"
  end

  # ── sidecar_output_dir takes precedence over sidecar_dir ────

  def test_shared_test_sidecar_output_dir_overrides_staging_base
    output_dir = File.join(@tmpdir, "override", "batches", "b1")
    seed_workflow(@ctrl_name,
                  status: "h_hardened",
                  analysis: analysis_fixture)
    stub_spawn_sequence([["FAIL", false], ["OK", true]])
    stub_claude_call(fix_tests_fixture)
    stub_copy_from_staging(@ctrl_path)

    @pipeline.send(:shared_test, @ctrl_name,
                   guard_status: "h_hardened",
                   testing_status: "h_testing",
                   fixing_status: "h_fixing_tests",
                   tested_status: "h_tested",
                   tests_failed_status: "h_tests_failed",
                   fix_prompt_fn: method(:passthrough_fix_prompt),
                   prompt_key: :test_fix,
                   sidecar_dir: ".should_not_be_used",
                   staging_subdir: "staging",
                   sidecar_output_dir: output_dir)

    # Staging under the output_dir, not under .should_not_be_used
    assert Dir.exist?(File.join(output_dir, "staging")),
           "Expected staging under sidecar_output_dir"
    refute Dir.exist?(File.join(File.dirname(@ctrl_path), ".should_not_be_used")),
           "sidecar_dir should not have been used when sidecar_output_dir is set"
  end

  private

  # ── Prompt capture helpers ──────────────────────────────────
  # These lambdas capture the analysis_json argument so tests can
  # verify it came from the correct workflow key.

  def capture_verify_prompt(ctrl_name, original_source, hardened_source, analysis_json)
    @captured_analysis_json = analysis_json
    "verify prompt for #{ctrl_name}"
  end

  def capture_apply_prompt(ctrl_name, source, analysis_json, decision, staging_dir:)
    @captured_analysis_json = analysis_json
    "apply prompt for #{ctrl_name}"
  end

  def capture_fix_prompt(ctrl_name, source, output, analysis_json, staging_dir:)
    @captured_analysis_json = analysis_json
    "fix prompt for #{ctrl_name}"
  end

  def capture_ci_fix_prompt(ctrl_name, source, failed_output, analysis_json, staging_dir:)
    @captured_analysis_json = analysis_json
    "ci fix prompt for #{ctrl_name}"
  end

  # Passthrough prompts (for sidecar tests that don't need to capture analysis)

  def passthrough_verify_prompt(ctrl_name, original_source, hardened_source, analysis_json)
    "verify prompt for #{ctrl_name}"
  end

  def passthrough_apply_prompt(ctrl_name, source, analysis_json, decision, staging_dir:)
    "apply prompt for #{ctrl_name}"
  end

  def passthrough_fix_prompt(ctrl_name, source, output, analysis_json, staging_dir:)
    "fix prompt for #{ctrl_name}"
  end

  def passthrough_ci_fix_prompt(ctrl_name, source, failed_output, analysis_json, staging_dir:)
    "ci fix prompt for #{ctrl_name}"
  end
end
