require "sinatra"
require "sinatra/streaming"
require "json"
require_relative "pipeline"

# ── Configuration ────────────────────────────────────────────

set :port, 4567
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
  halt 409, { error: "Not in selection phase" }.to_json unless $pipeline.state[:phase] == "awaiting_selection"

  body = JSON.parse(request.body.read)
  controller = body["controller"]
  halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?

  Thread.new { $pipeline.select_controller(controller) }

  { status: "analyzing", phase: "analyzing" }.to_json
end

# Load existing analysis from sidecar file (skip re-running claude)
post "/pipeline/load-analysis" do
  content_type :json
  halt 409, { error: "Not in selection phase" }.to_json unless $pipeline.state[:phase] == "awaiting_selection"

  body = JSON.parse(request.body.read)
  controller = body["controller"]
  halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?

  begin
    $pipeline.load_existing_analysis(controller)
    { status: "loaded", phase: "awaiting_decisions" }.to_json
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

# Submit decision for the active controller
# Body: { "action": "approve|selective|skip", "approved_findings": [...] }
post "/decisions" do
  content_type :json
  decision = JSON.parse(request.body.read)

  Thread.new { $pipeline.submit_decision(decision) }

  { status: "decision_received", phase: "hardening" }.to_json
end

# ── Ad-hoc Queries ──────────────────────────────────────────

# Ask a free-form question about the active controller
post "/ask" do
  content_type :json
  body = JSON.parse(request.body.read)
  question = body["question"]

  answer = $pipeline.ask_question(question)
  { question: question, answer: answer }.to_json
end

# Explain a specific finding
post "/explain/:finding_id" do
  content_type :json
  finding_id = params[:finding_id]

  explanation = $pipeline.explain_finding(finding_id)
  { finding_id: finding_id, explanation: explanation }.to_json
end

# ── Retry ────────────────────────────────────────────────────

post "/pipeline/retry" do
  content_type :json
  result = $pipeline.retry_analysis
  result.to_json
end

# ── Shutdown ──────────────────────────────────────────────

post "/shutdown" do
  content_type :json
  Thread.new { sleep 0.5; exit! }
  { status: "shutting_down" }.to_json
end
