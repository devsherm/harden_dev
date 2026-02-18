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

# Start the pipeline (discover controllers, then pause for selection)
post "/pipeline/start" do
  content_type :json
  halt 409, { error: "Pipeline already running" }.to_json unless $pipeline.state[:phase] == "idle"

  Thread.new { $pipeline.discover_controllers }

  { status: "started", phase: "discovering" }.to_json
end

# Analyze selected controllers
post "/pipeline/analyze" do
  content_type :json
  halt 409, { error: "Not in selection phase" }.to_json unless $pipeline.state[:phase] == "awaiting_selection"

  body = JSON.parse(request.body.read)
  controllers = body["controllers"]
  halt 400, { error: "No controllers specified" }.to_json if controllers.nil? || controllers.empty?

  Thread.new { $pipeline.select_controllers(controllers) }

  { status: "analyzing", phase: "analyzing" }.to_json
end

# Reset pipeline (for re-running)
post "/pipeline/reset" do
  content_type :json
  $pipeline = Pipeline.new(rails_root: RAILS_ROOT)
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

# ── Phase 2: Human Decisions ────────────────────────────────

# Submit decisions for all screens
# Body: { "projects_controller": { "action": "approve" }, ... }
post "/decisions" do
  content_type :json
  decisions = JSON.parse(request.body.read)

  Thread.new { $pipeline.submit_decisions(decisions) }

  { status: "decisions_received", phase: "hardening" }.to_json
end

# ── Ad-hoc Queries ──────────────────────────────────────────

# Ask a free-form question about a screen
post "/screens/:screen/ask" do
  content_type :json
  screen = params[:screen]
  body = JSON.parse(request.body.read)
  question = body["question"]

  answer = $pipeline.ask_about_screen(screen, question)
  { screen: screen, question: question, answer: answer }.to_json
end

# Explain a specific finding
post "/screens/:screen/explain/:finding_id" do
  content_type :json
  screen = params[:screen]
  finding_id = params[:finding_id]

  explanation = $pipeline.explain_finding(screen, finding_id)
  { screen: screen, finding_id: finding_id, explanation: explanation }.to_json
end

# ── Retry ────────────────────────────────────────────────────

post "/pipeline/retry/:screen" do
  content_type :json
  result = $pipeline.retry_screen(params[:screen])
  result.to_json
end

# ── Shutdown ──────────────────────────────────────────────

post "/shutdown" do
  content_type :json
  Thread.new { sleep 0.5; exit! }
  { status: "shutting_down" }.to_json
end
