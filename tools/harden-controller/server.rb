require "sinatra"
require "sinatra/streaming"
require "json"
require "socket"
require_relative "pipeline"

# ── Configuration ────────────────────────────────────────────

def find_open_port(preferred)
  TCPServer.open("0.0.0.0", preferred) { |s| s.addr[1] }
rescue Errno::EADDRINUSE
  # Let the OS pick an available port
  TCPServer.open("0.0.0.0", 0) { |s| s.addr[1] }
end

set :port, find_open_port((ENV["PORT"] || 4567).to_i)
set :bind, "0.0.0.0"
set :server, :puma
set :server_settings, { force_shutdown_after: 3 }

# Rails root defaults to current directory (run from within your Rails project)
RAILS_ROOT = ENV.fetch("RAILS_ROOT", ".")

$pipeline = Pipeline.new(rails_root: RAILS_ROOT)

%w[INT TERM].each do |sig|
  trap(sig) do
    $stderr.puts "Caught #{sig}, shutting down..."
    $pipeline.shutdown(timeout: 5)
    exit
  end
end

# Auto-discover controllers at startup so selection is the opening screen
$pipeline.safe_thread { $pipeline.discover_controllers }

# ── CORS (for local dev if frontend runs separately) ────────

before do
  headers "Access-Control-Allow-Origin" => "*",
          "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
          "Access-Control-Allow-Headers" => "Content-Type"
end

options "*" do
  200
end

# ── Helpers ──────────────────────────────────────────────────

helpers do
  def parse_json_body
    JSON.parse(request.body.read)
  rescue JSON::ParserError => e
    halt 400, { "Content-Type" => "application/json" },
         { error: "Invalid JSON: #{e.message}" }.to_json
  end
end

# ── Static UI ────────────────────────────────────────────────

get "/" do
  send_file File.join(__dir__, "index.html")
end

# ── Pipeline Control ─────────────────────────────────────────

# Analyze a single selected controller
post "/pipeline/analyze" do
  content_type :json
  halt 409, { error: "Discovery not complete" }.to_json unless $pipeline.phase == "ready"

  body = parse_json_body
  controller = body["controller"]
  halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?

  # Guard: workflow must not already be in an active status
  ws = $pipeline.workflow_status(controller)
  if ws && Pipeline::ACTIVE_STATUSES.include?(ws)
    halt 409, { error: "#{controller} is already #{ws}" }.to_json
  end

  $pipeline.safe_thread(workflow_name: controller) { $pipeline.select_controller(controller) }

  { status: "analyzing", controller: controller }.to_json
end

# Load existing analysis from sidecar file (skip re-running claude)
post "/pipeline/load-analysis" do
  content_type :json
  halt 409, { error: "Discovery not complete" }.to_json unless $pipeline.phase == "ready"

  body = parse_json_body
  controller = body["controller"]
  halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?

  ws = $pipeline.workflow_status(controller)
  if ws && Pipeline::ACTIVE_STATUSES.include?(ws)
    halt 409, { error: "#{controller} is already #{ws}" }.to_json
  end

  begin
    $pipeline.load_existing_analysis(controller)
    { status: "loaded", controller: controller }.to_json
  rescue => e
    halt 422, { error: e.message }.to_json
  end
end

# Reset pipeline (re-discovers controllers)
post "/pipeline/reset" do
  content_type :json
  $pipeline.reset!
  $pipeline.safe_thread { $pipeline.discover_controllers }
  { status: "reset" }.to_json
end

# Current state snapshot
get "/pipeline/status" do
  content_type :json
  $pipeline.to_json
end

# Retrieve prompt for a specific controller and phase
get "/pipeline/:name/prompts/:phase" do
  content_type :json
  prompt = $pipeline.get_prompt(params[:name], params[:phase].to_sym)
  halt 404, { error: "No prompt found" }.to_json unless prompt
  { controller: params[:name], phase: params[:phase], prompt: prompt }.to_json
end

# ── SSE Stream ───────────────────────────────────────────────

get "/events" do
  content_type "text/event-stream"
  cache_control :no_cache

  stream(:keep_open) do |out|
    last_json = nil
    loop do
      current_json = $pipeline.to_json
      if current_json != last_json
        out << "data: #{current_json}\n\n"
        last_json = current_json
      end
      sleep 0.5
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET
      break
    end
  end
end

# ── Phase 2: Human Decision ─────────────────────────────────

# Submit decision for a controller
# Body: { "controller": "...", "action": "approve|selective|skip", "approved_findings": [...] }
post "/decisions" do
  content_type :json
  body = parse_json_body
  controller = body.delete("controller")
  halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?

  halt 404, { error: "No workflow for #{controller}" }.to_json unless $pipeline.workflow_exists?(controller)
  ws = $pipeline.workflow_status(controller)
  halt 409, { error: "#{controller} is not awaiting decisions" }.to_json unless ws == "awaiting_decisions"

  $pipeline.safe_thread(workflow_name: controller) { $pipeline.submit_decision(controller, body) }

  { status: "decision_received", controller: controller }.to_json
end

# ── Ad-hoc Queries ──────────────────────────────────────────

# Ask a free-form question about a controller
post "/ask" do
  content_type :json
  body = parse_json_body
  controller = body["controller"]
  question = body["question"]
  halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?

  result = $pipeline.ask_question(controller, question)
  status 202
  result.to_json
end

# Explain a specific finding
post "/explain/:finding_id" do
  content_type :json
  body = parse_json_body
  controller = body["controller"]
  finding_id = params[:finding_id]
  halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?

  result = $pipeline.explain_finding(controller, finding_id)
  status 202
  result.to_json
end

# ── Retry Tests ─────────────────────────────────────────────

post "/pipeline/retry-tests" do
  content_type :json
  body = parse_json_body
  controller = body["controller"]
  halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?

  halt 404, { error: "No workflow for #{controller}" }.to_json unless $pipeline.workflow_exists?(controller)
  ws = $pipeline.workflow_status(controller)
  halt 409, { error: "#{controller} is not in tests_failed state" }.to_json unless ws == "tests_failed"

  $pipeline.safe_thread(workflow_name: controller) { $pipeline.retry_tests(controller) }

  { status: "retrying_tests", controller: controller }.to_json
end

# ── Retry CI ──────────────────────────────────────────────────

post "/pipeline/retry-ci" do
  content_type :json
  body = parse_json_body
  controller = body["controller"]
  halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?

  halt 404, { error: "No workflow for #{controller}" }.to_json unless $pipeline.workflow_exists?(controller)
  ws = $pipeline.workflow_status(controller)
  halt 409, { error: "#{controller} is not in ci_failed state" }.to_json unless ws == "ci_failed"

  $pipeline.safe_thread(workflow_name: controller) { $pipeline.retry_ci(controller) }

  { status: "retrying_ci", controller: controller }.to_json
end

# ── Retry ────────────────────────────────────────────────────

post "/pipeline/retry" do
  content_type :json
  body = parse_json_body
  controller = body["controller"]
  halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?

  halt 404, { error: "No workflow for #{controller}" }.to_json unless $pipeline.workflow_exists?(controller)
  ws = $pipeline.workflow_status(controller)
  halt 409, { error: "#{controller} is not in error state" }.to_json unless ws == "error"

  result = $pipeline.retry_analysis(controller)
  result.to_json
end

# ── Shutdown ──────────────────────────────────────────────

post "/shutdown" do
  content_type :json
  Thread.new do
    sleep 0.1  # let response flush
    $pipeline.shutdown(timeout: 5)
    exit
  end
  { status: "shutting_down" }.to_json
end
