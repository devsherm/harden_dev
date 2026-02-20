require "sinatra"
require "sinatra/streaming"
require "json"
require "socket"
require "securerandom"
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
set :run, false

set :sessions, same_site: :lax, secure: (ENV["RACK_ENV"] != "test"), httponly: true
set :session_secret, ENV.fetch("SESSION_SECRET") { SecureRandom.hex(64) }
# Host auth is handled by passcode; allow any host (ngrok, LAN, rack-test)
set :host_authorization, permitted_hosts: []

module HardenAuth
  @passcode = ENV["HARDEN_PASSCODE"]
  class << self; attr_accessor :passcode; end
end

configure do
  if HardenAuth.passcode.nil?
    bind_addr = settings.bind
    unless bind_addr == "127.0.0.1" || bind_addr == "localhost"
      HardenAuth.passcode = SecureRandom.hex(12)
      $stderr.puts "=" * 60
      $stderr.puts "WARNING: No HARDEN_PASSCODE set while binding to #{bind_addr}"
      $stderr.puts "Auto-generated passcode: #{HardenAuth.passcode}"
      $stderr.puts "Set HARDEN_PASSCODE env var to use your own."
      $stderr.puts "=" * 60
    end
  end
end

# ── Rate limiting for /auth ─────────────────────────────────
AUTH_ATTEMPTS = {}  # ip => { count:, first_at: }
AUTH_MAX_ATTEMPTS = 5
AUTH_WINDOW = 900  # 15 minutes

# Rails root defaults to current directory (run from within your Rails project)
RAILS_ROOT = ENV.fetch("RAILS_ROOT", ".")

$pipeline = Pipeline.new(rails_root: RAILS_ROOT)

%w[INT TERM].each do |sig|
  trap(sig) do
    $stderr.puts "Caught #{sig}, shutting down..."
    $pipeline.cancel!   # just sets @cancelled = true, no mutex
    exit
  end
end

at_exit { $pipeline.shutdown(timeout: 5) }

# Auto-discover controllers at startup so selection is the opening screen
$pipeline.safe_thread { $pipeline.discover_controllers }

# ── CORS (opt-in for separate frontend during local dev) ────

CORS_ORIGIN = ENV["CORS_ORIGIN"]

before do
  if request.post? && request.content_length && request.content_length.to_i > 1_048_576
    halt 413, { "Content-Type" => "application/json" },
         { error: "Request body too large" }.to_json
  end

  if CORS_ORIGIN
    headers "Access-Control-Allow-Origin" => CORS_ORIGIN,
            "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers" => "Content-Type, X-Requested-With"
  end

  # ── Passcode auth gate ──────────────────────────────────
  next if HardenAuth.passcode.nil?                         # no passcode configured → open
  next if request.path_info == "/auth" && request.post? # login endpoint
  next if request.options?                              # CORS preflight

  unless session[:authenticated]
    if request.path_info == "/" && request.get?
      halt 200, { "Content-Type" => "text/html" }, login_page
    else
      halt 401, { "Content-Type" => "application/json" },
           { error: "Unauthorized" }.to_json
    end
  end

  # ── CSRF protection ─────────────────────────────────────
  if request.post? && request.path_info != "/auth"
    unless request.env["HTTP_X_REQUESTED_WITH"] == "XMLHttpRequest"
      halt 403, { "Content-Type" => "application/json" },
           { error: "Missing X-Requested-With header" }.to_json
    end
  end
end

after do
  headers "X-Frame-Options"           => "DENY",
          "X-Content-Type-Options"     => "nosniff",
          "Referrer-Policy"            => "no-referrer",
          "Content-Security-Policy"    => "default-src 'none'; script-src 'self' https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self'; frame-ancestors 'none'",
          "Strict-Transport-Security"  => "max-age=63072000; includeSubDomains"
end

if CORS_ORIGIN
  options("*") { 200 }
end

# ── Helpers ──────────────────────────────────────────────────

helpers do
  def parse_json_body
    JSON.parse(request.body.read)
  rescue JSON::ParserError => e
    halt 400, { "Content-Type" => "application/json" },
         { error: "Invalid JSON: #{e.message}" }.to_json
  end

  def login_page
    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Harden Orchestrator — Login</title>
        <style>
          * { box-sizing: border-box; margin: 0; padding: 0; }
          body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace;
            background: #0f1117; color: #e1e4ed;
            display: flex; align-items: center; justify-content: center;
            height: 100vh;
          }
          .login-box {
            background: #1a1d27; border: 1px solid #2a2e3b; border-radius: 8px;
            padding: 2rem; width: 320px; text-align: center;
          }
          h1 { font-size: 1.2rem; margin-bottom: 1.5rem; }
          input {
            width: 100%; padding: 0.6rem 0.8rem; margin-bottom: 1rem;
            background: #0f1117; border: 1px solid #2a2e3b; border-radius: 4px;
            color: #e1e4ed; font-size: 0.9rem;
          }
          input:focus { outline: none; border-color: #6c8cff; }
          button {
            width: 100%; padding: 0.6rem; background: #2563eb; border: none;
            border-radius: 4px; color: #e1e4ed; font-size: 0.9rem; cursor: pointer;
          }
          button:hover { background: #1d4ed8; }
          .error { color: #f87171; font-size: 0.85rem; margin-bottom: 1rem; }
        </style>
      </head>
      <body>
        <div class="login-box">
          <h1>Harden Orchestrator</h1>
          <form method="POST" action="/auth">
            <input type="password" name="passcode" placeholder="Passcode" autofocus required />
            <button type="submit">Login</button>
          </form>
        </div>
      </body>
      </html>
    HTML
  end
end

# ── Authentication ───────────────────────────────────────────

post "/auth" do
  client_ip = request.ip

  # ── Rate limiting ───────────────────────────────────────
  attempt = AUTH_ATTEMPTS[client_ip]
  if attempt && attempt[:count] >= AUTH_MAX_ATTEMPTS && (Time.now.to_i - attempt[:first_at]) < AUTH_WINDOW
    halt 429, { "Content-Type" => "text/html" }, login_page.sub(
      "</form>",
      '<div class="error">Too many attempts. Try again later.</div></form>'
    )
  end

  if HardenAuth.passcode && Rack::Utils.secure_compare(params["passcode"].to_s, HardenAuth.passcode)
    AUTH_ATTEMPTS.delete(client_ip)
    env["rack.session.options"][:renew] = true   # regenerate session ID (prevent fixation)
    session[:authenticated] = true
    redirect "/"
  elsif HardenAuth.passcode.nil?
    redirect "/"
  else
    now = Time.now.to_i
    if attempt.nil? || (now - attempt[:first_at]) >= AUTH_WINDOW
      AUTH_ATTEMPTS[client_ip] = { count: 1, first_at: now }
    else
      attempt[:count] += 1
    end
    # Prune expired entries to prevent memory growth
    AUTH_ATTEMPTS.delete_if { |_, v| (now - v[:first_at]) >= AUTH_WINDOW }

    halt 401, { "Content-Type" => "text/html" }, login_page.sub(
      "</form>",
      '<div class="error">Invalid passcode</div></form>'
    )
  end
end

post "/auth/logout" do
  session.clear
  redirect "/"
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

  ok, err = $pipeline.try_transition(controller, guard: :not_active, to: "analyzing")
  halt 409, { error: err }.to_json unless ok

  $pipeline.safe_thread(workflow_name: controller) { $pipeline.run_analysis(controller) }

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
    halt 422, { error: $pipeline.send(:sanitize_error, e.message) }.to_json
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

SSE_TIMEOUT = 1200  # 20 minutes
SSE_MAX_CONNECTIONS = 4
$sse_connections = Mutex.new
$sse_count = 0

get "/events" do
  content_type "text/event-stream"
  cache_control :no_cache

  $sse_connections.synchronize do
    if $sse_count >= SSE_MAX_CONNECTIONS
      halt 429, { "Content-Type" => "application/json" },
           { error: "Too many SSE connections" }.to_json
    end
    $sse_count += 1
  end

  begin
    stream(:keep_open) do |out|
      last_json = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SSE_TIMEOUT
      loop do
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          out << "event: timeout\ndata: {}\n\n"
          break
        end
        current_json = $pipeline.to_json
        if current_json != last_json
          out << "data: #{current_json}\n\n"
          last_json = current_json
        end
        sleep 0.5
      rescue IOError, Errno::EPIPE, Errno::ECONNRESET
        break
      rescue => e
        $stderr.puts "[SSE] Unexpected error: #{e.class}: #{e.message}"
        break
      end
    end
  ensure
    $sse_connections.synchronize { $sse_count -= 1 }
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

  ok, err = $pipeline.try_transition(controller, guard: "awaiting_decisions", to: "hardening")
  halt 409, { error: err }.to_json unless ok

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

  ok, err = $pipeline.try_transition(controller, guard: "tests_failed", to: "hardened")
  halt 409, { error: err }.to_json unless ok

  $pipeline.safe_thread(workflow_name: controller) { $pipeline.run_testing(controller) }

  { status: "retrying_tests", controller: controller }.to_json
end

# ── Retry CI ──────────────────────────────────────────────────

post "/pipeline/retry-ci" do
  content_type :json
  body = parse_json_body
  controller = body["controller"]
  halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?

  ok, err = $pipeline.try_transition(controller, guard: "ci_failed", to: "tested")
  halt 409, { error: err }.to_json unless ok

  $pipeline.safe_thread(workflow_name: controller) { $pipeline.run_ci_checks(controller) }

  { status: "retrying_ci", controller: controller }.to_json
end

# ── Retry ────────────────────────────────────────────────────

post "/pipeline/retry" do
  content_type :json
  body = parse_json_body
  controller = body["controller"]
  halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?

  ok, err = $pipeline.try_transition(controller, guard: "error", to: "analyzing")
  halt 409, { error: err }.to_json unless ok

  $pipeline.safe_thread(workflow_name: controller) { $pipeline.run_analysis(controller) }

  { status: "retrying", controller: controller }.to_json
end

# ── Shutdown ──────────────────────────────────────────────

post "/shutdown" do
  content_type :json
  Thread.new do
    sleep 0.1  # let response flush
    $pipeline.shutdown(timeout: 5)
  rescue => e
    $stderr.puts "Shutdown error: #{e.message}"
  ensure
    exit
  end
  { status: "shutting_down" }.to_json
end

# ── Manual startup with TOCTOU retry ────────────────────────

if __FILE__ == $PROGRAM_NAME
  MAX_PORT_RETRIES = 3

  retries = 0
  begin
    Sinatra::Application.run!
  rescue Errno::EADDRINUSE
    retries += 1
    if retries < MAX_PORT_RETRIES
      new_port = TCPServer.open("0.0.0.0", 0) { |s| s.addr[1] }
      $stderr.puts "Port #{settings.port} in use, retrying on #{new_port}..."
      set :port, new_port
      retry
    end
    raise
  end
end
