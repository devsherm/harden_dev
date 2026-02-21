require "json"
require "time"
require "open3"
require "fileutils"
require "shellwords"
require "securerandom"
require "net/http"
require "uri"
require_relative "prompts"

class Pipeline
  ACTIVE_STATUSES = %w[
    h_analyzing h_hardening h_testing h_fixing_tests
    h_ci_checking h_fixing_ci h_verifying
    e_analyzing e_extracting e_synthesizing
    e_auditing e_planning_batches e_applying e_testing
    e_fixing_tests e_ci_checking e_fixing_ci e_verifying
  ].freeze
  CLAUDE_TIMEOUT = 120
  COMMAND_TIMEOUT = 60
  MAX_QUERIES = 50
  MAX_CLAUDE_CONCURRENCY = 12
  MAX_API_CONCURRENCY = 20
  MAX_FIX_ATTEMPTS = 2
  MAX_CI_FIX_ATTEMPTS = 2

  CI_CHECKS = [
    { name: "rubocop", cmd: ->(path) { ["bin/rubocop", path] } },
    { name: "brakeman", cmd: ->(_) { %w[bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error] } },
    { name: "bundler-audit", cmd: ->(_) { %w[bin/bundler-audit] } },
    { name: "importmap-audit", cmd: ->(_) { %w[bin/importmap audit] } }
  ].freeze
end

require_relative "pipeline/process_management"
require_relative "pipeline/claude_client"
require_relative "pipeline/sidecar"
require_relative "pipeline/shared_phases"
require_relative "pipeline/orchestration"
require_relative "pipeline/enhance_orchestration"
require_relative "pipeline/lock_manager"
require_relative "pipeline/scheduler"

class Pipeline
  include ProcessManagement
  include ClaudeClient
  include Sidecar
  include SharedPhases
  include Orchestration
  include EnhanceOrchestration

  # Synchronized accessors — never expose @state directly.
  # Use workflow_status / workflow_data for route guards.

  def phase
    @mutex.synchronize { @state[:phase] }
  end

  def scheduler
    @scheduler
  end

  def workflow_status(name)
    @mutex.synchronize { @state[:workflows][name]&.[](:status) }
  end

  def workflow_exists?(name)
    @mutex.synchronize { @state[:workflows].key?(name) }
  end

  def workflow_data(name, key)
    @mutex.synchronize { @state[:workflows][name]&.[](key) }
  end

  # Atomically verify guard condition and transition workflow status.
  # For :not_active guard, creates the workflow if it doesn't exist.
  # Returns [true, nil] on success, [false, error_string] on failure.
  def try_transition(name, guard:, to:)
    @mutex.synchronize do
      wf = @state[:workflows][name]
      status = wf&.[](:status)

      case guard
      when :not_active
        if status && ACTIVE_STATUSES.include?(status)
          return [false, "#{name} is already #{status}"]
        end
        entry = @state[:controllers].find { |c| c[:name] == name }
        return [false, "Controller not found: #{name}"] unless entry
        @state[:workflows][name] = build_workflow(entry.dup).merge(status: to, error: nil, started_at: Time.now.iso8601)
      when Array
        return [false, "No workflow for #{name}"] unless wf
        return [false, "#{name} is #{status}, expected one of #{guard.join(', ')}"] unless guard.map(&:to_s).include?(status)
        wf[:status] = to
        wf[:error] = nil
      else
        return [false, "No workflow for #{name}"] unless wf
        return [false, "#{name} is #{status}, expected #{guard}"] unless status == guard.to_s
        wf[:status] = to
        wf[:error] = nil
      end

      [true, nil]
    end
  end

  def initialize(rails_root: ".", sidecar_dir: ".harden",
                 allowed_write_paths: ["app/controllers"],
                 discovery_glob: "app/controllers/**/*_controller.rb",
                 discovery_excludes: ["application_controller"],
                 test_path_resolver: nil,
                 enhance_sidecar_dir: ".enhance",
                 enhance_allowed_write_paths: ["app/controllers", "app/views", "app/models", "app/services", "test/"],
                 api_key: ENV["ANTHROPIC_API_KEY"],
                 lock_manager: nil,
                 scheduler: nil)
    @rails_root = rails_root
    @sidecar_dir = sidecar_dir
    @allowed_write_paths = allowed_write_paths
    @discovery_glob = discovery_glob
    @discovery_excludes = discovery_excludes
    @test_path_resolver = test_path_resolver || method(:default_derive_test_path)
    @enhance_sidecar_dir = enhance_sidecar_dir
    @enhance_allowed_write_paths = enhance_allowed_write_paths
    @api_key = api_key
    @mutex = Mutex.new
    @threads = []
    @cancelled = false
    @state = {
      phase: "idle",       # global: "idle" | "discovering" | "ready"
      controllers: [],     # discovery list (unchanged)
      workflows: {},       # keyed by controller name
      errors: []
    }
    @prompt_store = {}  # keyed by controller name → phase symbol
    @queries = []  # [{id:, controller:, type:, question:, finding_id:, status:, result:, error:, created_at:}]
    @cached_json = nil
    @last_serialized_at = 0
    @claude_semaphore = Mutex.new
    @claude_slots = ConditionVariable.new
    @claude_active = 0
    @api_semaphore = Mutex.new
    @api_slots = ConditionVariable.new
    @api_active = 0
    @lock_manager = lock_manager || LockManager.new
    @scheduler = scheduler || Scheduler.new(
      lock_manager: @lock_manager,
      slot_available_fn: -> { @claude_active < MAX_CLAUDE_CONCURRENCY },
      safe_thread_fn: ->(block = nil, &blk) { safe_thread(&(block || blk)) }
    )
    @scheduler.start
  end

  def reset!
    shutdown(timeout: 5)
    # Force-kill any stragglers — shutdown already attempted join + kill,
    # but verify before clearing state.
    @mutex.synchronize do
      @threads.each { |t| t.kill if t.alive? }
      @threads.clear
      @cancelled = false
      @state[:phase] = "idle"
      @state[:controllers] = []
      @state[:workflows] = {}
      @state[:errors] = []
      @prompt_store.clear
      @queries.clear
      @claude_active = 0
      @api_active = 0
    end
    # Second drain: catch threads that snuck in between shutdown and the
    # mutex block above (race window where safe_thread could still append).
    stragglers = @mutex.synchronize { @threads.dup }
    stragglers.each { |t| t.kill if t.alive? }
    stragglers.each { |t| t.join(2) }
    # Clear enhance mode state
    @lock_manager.release_all
    @scheduler.stop
  end

  # ── Helpers ─────────────────────────────────────────────────

  def to_json(*args)
    @mutex.synchronize do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if @cached_json.nil? || (now - @last_serialized_at) > 0.1
        enriched = @state[:workflows].transform_values do |wf|
          store = @prompt_store[wf[:name]]
          store ? wf.merge(prompts: store.transform_values { true }) : wf
        end
        lock_state = {
          active_grants: @lock_manager.active_grants,
          queue_depth:   @scheduler.queue_depth,
          active_items:  @scheduler.active_items
        }
        @cached_json = @state.merge(
          workflows: enriched,
          queries: @queries,
          locks: lock_state
        ).to_json(*args)
        @last_serialized_at = now
      end
      @cached_json
    end
  end

  def get_prompt(controller_name, phase)
    @mutex.synchronize { @prompt_store.dig(controller_name, phase) }
  end

  def sanitize_error(msg)
    msg.gsub(@rails_root, "<project>")
       .gsub(File.realpath(@rails_root), "<project>")
  rescue StandardError
    msg
  end

  private

  def find_controller(name)
    entry = @mutex.synchronize { @state[:controllers].find { |c| c[:name] == name } }
    raise "Controller not found: #{name}" unless entry
    entry.dup
  end

  def build_workflow(entry)
    {
      name: entry[:name],
      path: entry[:path],
      full_path: entry[:full_path],
      status: "pending",
      mode: "hardening",
      analysis: nil,
      decision: nil,
      hardened: nil,
      test_results: nil,
      ci_results: nil,
      verification: nil,
      error: nil,
      started_at: nil,
      completed_at: nil,
      original_source: nil
    }
  end

  def add_error(msg)
    @state[:errors] << { message: sanitize_error(msg), at: Time.now.iso8601 }
  end

  # Drop oldest completed queries when over the cap (caller holds @mutex)
  def prune_queries
    return if @queries.length <= MAX_QUERIES
    removable = @queries.select { |q| %w[complete error].include?(q[:status]) }
    remove_count = @queries.length - MAX_QUERIES
    removable.first(remove_count).each { |q| @queries.delete(q) }
    # If still over cap (too many pending), drop oldest pending
    @queries.shift while @queries.length > MAX_QUERIES
  end
end
