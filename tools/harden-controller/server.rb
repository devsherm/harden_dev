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

# Auto-discover controllers at startup so selection is the opening screen
Thread.new { $pipeline.discover_controllers }

# ── CORS (for local dev if frontend runs separately) ────────

before do
  headers "Access-Control-Allow-Origin" => "*",
          "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
          "Access-Control-Allow-Headers" => "Content-Type"
end

options "*" do
  200
end

# ── Static UI ────────────────────────────────────────────────

get "/" do
  send_file File.join(__dir__, "index.html")
end

# ── Pipeline Control ─────────────────────────────────────────

# Analyze a single selected controller
post "/pipeline/analyze" do
  content_type :json
  halt 409, { error: "Discovery not complete" }.to_json unless $pipeline.state[:phase] == "ready"

  body = JSON.parse(request.body.read)
  controller = body["controller"]
  halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?

  # Guard: workflow must not already be in an active phase
  workflow = $pipeline.state[:workflows][controller]
  if workflow && Pipeline::ACTIVE_PHASES.include?(workflow[:phase])
    halt 409, { error: "#{controller} is already #{workflow[:phase]}" }.to_json
  end

  Thread.new { $pipeline.select_controller(controller) }

  { status: "analyzing", controller: controller }.to_json
end

# Load existing analysis from sidecar file (skip re-running claude)
post "/pipeline/load-analysis" do
  content_type :json
  halt 409, { error: "Discovery not complete" }.to_json unless $pipeline.state[:phase] == "ready"

  body = JSON.parse(request.body.read)
  controller = body["controller"]
  halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?

  workflow = $pipeline.state[:workflows][controller]
  if workflow && Pipeline::ACTIVE_PHASES.include?(workflow[:phase])
    halt 409, { error: "#{controller} is already #{workflow[:phase]}" }.to_json
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
  $pipeline = Pipeline.new(rails_root: RAILS_ROOT)
  Thread.new { $pipeline.discover_controllers }
  { status: "reset" }.to_json
end

# Current state snapshot
get "/pipeline/status" do
  content_type :json
  $pipeline.to_json
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
    rescue IOError
      break
    end
  end
end

# ── Phase 2: Human Decision ─────────────────────────────────

# Submit decision for a controller
# Body: { "controller": "...", "action": "approve|selective|skip", "approved_findings": [...] }
post "/decisions" do
  content_type :json
  body = JSON.parse(request.body.read)
  controller = body.delete("controller")
  halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?

  workflow = $pipeline.state[:workflows][controller]
  halt 404, { error: "No workflow for #{controller}" }.to_json unless workflow
  halt 409, { error: "#{controller} is not awaiting decisions" }.to_json unless workflow[:phase] == "awaiting_decisions"

  Thread.new { $pipeline.submit_decision(controller, body) }

  { status: "decision_received", controller: controller }.to_json
end

# ── Ad-hoc Queries ──────────────────────────────────────────

# Ask a free-form question about a controller
post "/ask" do
  content_type :json
  body = JSON.parse(request.body.read)
  controller = body["controller"]
  question = body["question"]
  halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?

  answer = $pipeline.ask_question(controller, question)
  { controller: controller, question: question, answer: answer }.to_json
end

# Explain a specific finding
post "/explain/:finding_id" do
  content_type :json
  body = JSON.parse(request.body.read)
  controller = body["controller"]
  finding_id = params[:finding_id]
  halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?

  explanation = $pipeline.explain_finding(controller, finding_id)
  { controller: controller, finding_id: finding_id, explanation: explanation }.to_json
end

# ── Retry Tests ─────────────────────────────────────────────

post "/pipeline/retry-tests" do
  content_type :json
  body = JSON.parse(request.body.read)
  controller = body["controller"]
  halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?

  workflow = $pipeline.state[:workflows][controller]
  halt 404, { error: "No workflow for #{controller}" }.to_json unless workflow
  halt 409, { error: "#{controller} is not in tests_failed state" }.to_json unless workflow[:status] == "tests_failed"

  Thread.new { $pipeline.retry_tests(controller) }

  { status: "retrying_tests", controller: controller }.to_json
end

# ── Retry CI ──────────────────────────────────────────────────

post "/pipeline/retry-ci" do
  content_type :json
  body = JSON.parse(request.body.read)
  controller = body["controller"]
  halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?

  workflow = $pipeline.state[:workflows][controller]
  halt 404, { error: "No workflow for #{controller}" }.to_json unless workflow
  halt 409, { error: "#{controller} is not in ci_failed state" }.to_json unless workflow[:status] == "ci_failed"

  Thread.new { $pipeline.retry_ci(controller) }

  { status: "retrying_ci", controller: controller }.to_json
end

# ── Retry ────────────────────────────────────────────────────

post "/pipeline/retry" do
  content_type :json
  body = JSON.parse(request.body.read)
  controller = body["controller"]
  halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?

  result = $pipeline.retry_analysis(controller)
  result.to_json
end

# ── Shutdown ──────────────────────────────────────────────

post "/shutdown" do
  content_type :json
  Thread.new { sleep 0.5; exit! }
  { status: "shutting_down" }.to_json
end
