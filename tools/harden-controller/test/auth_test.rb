require "minitest/autorun"
require "rack/test"
require "tmpdir"
require "fileutils"

# Prevent $pipeline.discover_controllers from running during require
ENV["RACK_ENV"] = "test"
ENV["RAILS_ROOT"] ||= Dir.mktmpdir("harden-auth-test-")

require_relative "../server"

class AuthTestCase < Minitest::Test
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  def setup
    # Clear session state between tests by resetting the cookie jar
    clear_cookies
  end

  private

  def silence_warnings
    old_verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = old_verbose
  end

  def xhr_post(path, params = {})
    post path, params, { "HTTP_X_REQUESTED_WITH" => "XMLHttpRequest" }
  end
end

class AuthDisabledTest < AuthTestCase
  def setup
    super
    @original_passcode = HardenAuth.passcode
    HardenAuth.passcode = nil
  end

  def teardown
    HardenAuth.passcode = @original_passcode
  end

  def test_get_root_serves_index_without_auth
    get "/"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Harden Orchestrator"
    # Should serve the main UI, not the login page
    refute_includes last_response.body, "login-box"
  end

  def test_get_status_accessible_without_auth
    get "/pipeline/status"
    assert_equal 200, last_response.status
  end

  def test_post_auth_redirects_to_root
    post "/auth", passcode: "anything"
    assert_equal 302, last_response.status
    assert_equal "/", URI.parse(last_response.headers["Location"]).path
  end

  def test_logout_redirects_to_root
    post "/auth/logout"
    assert_equal 302, last_response.status
    assert_equal "/", URI.parse(last_response.headers["Location"]).path
  end
end

class AuthEnabledTest < AuthTestCase
  PASSCODE = "test-secret-123"

  def setup
    super
    @original_passcode = HardenAuth.passcode
    HardenAuth.passcode = PASSCODE
  end

  def teardown
    HardenAuth.passcode = @original_passcode
  end

  def test_get_root_shows_login_page
    get "/"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "login-box"
    assert_includes last_response.body, "Passcode"
  end

  def test_api_route_returns_401
    get "/pipeline/status"
    assert_equal 401, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "Unauthorized", body["error"]
  end

  def test_post_route_returns_401
    post "/pipeline/reset"
    assert_equal 401, last_response.status
  end

  def test_options_bypasses_auth
    options "/pipeline/status"
    # OPTIONS is not blocked by auth (before filter skips auth for OPTIONS)
    refute_equal 401, last_response.status
  end

  def test_correct_passcode_sets_session
    post "/auth", passcode: PASSCODE
    assert_equal 302, last_response.status

    # Follow redirect — should get main UI, not login page
    follow_redirect!
    assert_equal 200, last_response.status
    refute_includes last_response.body, "login-box"
  end

  def test_wrong_passcode_shows_error
    post "/auth", passcode: "wrong"
    assert_equal 401, last_response.status
    assert_includes last_response.body, "Invalid passcode"
    assert_includes last_response.body, "login-box"
  end

  def test_authenticated_session_can_access_routes
    # Log in
    post "/auth", passcode: PASSCODE
    follow_redirect!

    # Now API routes should work
    get "/pipeline/status"
    assert_equal 200, last_response.status
  end

  def test_logout_clears_session
    # Log in
    post "/auth", passcode: PASSCODE
    follow_redirect!

    # Verify access
    get "/pipeline/status"
    assert_equal 200, last_response.status

    # Log out (requires X-Requested-With for CSRF protection)
    xhr_post "/auth/logout"
    assert_equal 302, last_response.status

    # Should be locked out again
    get "/pipeline/status"
    assert_equal 401, last_response.status
  end

  def test_sse_endpoint_returns_401
    get "/events"
    assert_equal 401, last_response.status
  end
end

# ── CSRF Protection Tests ───────────────────────────────────

class CsrfTest < AuthTestCase
  PASSCODE = "test-secret-123"

  def setup
    super
    @original_passcode = HardenAuth.passcode
    HardenAuth.passcode = PASSCODE
    # Authenticate for all CSRF tests
    post "/auth", passcode: PASSCODE
    follow_redirect!
  end

  def teardown
    HardenAuth.passcode = @original_passcode
  end

  def test_post_without_xhr_header_returns_403
    post "/pipeline/reset"
    assert_equal 403, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "Missing X-Requested-With header", body["error"]
  end

  def test_post_with_xhr_header_succeeds
    xhr_post "/pipeline/reset"
    assert_equal 200, last_response.status
  end

  def test_post_to_auth_exempt_from_csrf
    # The login form POST to /auth should not require X-Requested-With
    post "/auth", passcode: PASSCODE
    assert_equal 302, last_response.status
  end

  def test_logout_without_xhr_returns_403
    post "/auth/logout"
    assert_equal 403, last_response.status
  end

  def test_logout_with_xhr_succeeds
    xhr_post "/auth/logout"
    assert_equal 302, last_response.status
  end
end

# ── Rate Limiting Tests ─────────────────────────────────────

class RateLimitTest < AuthTestCase
  PASSCODE = "test-secret-123"

  def setup
    super
    @original_passcode = HardenAuth.passcode
    HardenAuth.passcode = PASSCODE
    AUTH_ATTEMPTS.clear
  end

  def teardown
    HardenAuth.passcode = @original_passcode
    AUTH_ATTEMPTS.clear
  end

  def test_five_failures_then_429
    AUTH_MAX_ATTEMPTS.times do
      post "/auth", passcode: "wrong"
      assert_equal 401, last_response.status
    end

    post "/auth", passcode: "wrong"
    assert_equal 429, last_response.status
    assert_includes last_response.body, "Too many attempts"
  end

  def test_correct_passcode_rejected_when_locked_out
    AUTH_MAX_ATTEMPTS.times { post "/auth", passcode: "wrong" }

    # Even the correct passcode is rejected
    post "/auth", passcode: PASSCODE
    assert_equal 429, last_response.status
  end

  def test_success_resets_counter
    3.times { post "/auth", passcode: "wrong" }

    # Successful login resets the counter
    post "/auth", passcode: PASSCODE
    assert_equal 302, last_response.status

    # Counter should be reset — full window of failures available again
    AUTH_MAX_ATTEMPTS.times do
      post "/auth", passcode: "wrong"
      assert_equal 401, last_response.status
    end

    post "/auth", passcode: "wrong"
    assert_equal 429, last_response.status
  end
end

# ── CORS Tests ──────────────────────────────────────────────

# ── Security Headers Tests ─────────────────────────────────

class SecurityHeadersTest < AuthTestCase
  def setup
    super
    @original_passcode = HardenAuth.passcode
    HardenAuth.passcode = nil  # disable auth to simplify header testing
  end

  def teardown
    HardenAuth.passcode = @original_passcode
  end

  def test_get_response_includes_security_headers
    get "/"
    assert_equal "DENY", last_response.headers["X-Frame-Options"]
    assert_equal "nosniff", last_response.headers["X-Content-Type-Options"]
    assert_equal "no-referrer", last_response.headers["Referrer-Policy"]
    assert_includes last_response.headers["Content-Security-Policy"], "default-src 'none'"
    assert_includes last_response.headers["Content-Security-Policy"], "frame-ancestors 'none'"
    assert_includes last_response.headers["Strict-Transport-Security"], "max-age=63072000"
  end

  def test_post_response_includes_security_headers
    post "/auth", passcode: "anything"
    # Follow redirect to check headers on final response
    follow_redirect!
    assert_equal "DENY", last_response.headers["X-Frame-Options"]
    assert_equal "nosniff", last_response.headers["X-Content-Type-Options"]
    assert_equal "no-referrer", last_response.headers["Referrer-Policy"]
  end

  def test_json_endpoint_includes_security_headers
    get "/pipeline/status"
    assert_equal "DENY", last_response.headers["X-Frame-Options"]
    assert_equal "nosniff", last_response.headers["X-Content-Type-Options"]
  end
end

# ── SSE Connection Cap Tests ──────────────────────────────

class SseConnectionCapTest < AuthTestCase
  def setup
    super
    @original_passcode = HardenAuth.passcode
    HardenAuth.passcode = nil  # disable auth to simplify SSE testing
    # Reset SSE counter between tests
    $sse_connections.synchronize { $sse_count = 0 }
  end

  def teardown
    HardenAuth.passcode = @original_passcode
    $sse_connections.synchronize { $sse_count = 0 }
  end

  def test_sse_connection_rejected_at_cap
    # Simulate SSE_MAX_CONNECTIONS already taken
    $sse_connections.synchronize { $sse_count = SSE_MAX_CONNECTIONS }

    get "/events"
    assert_equal 429, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "Too many SSE connections", body["error"]
  end

end

# ── Session Fixation Tests ─────────────────────────────────

class SessionFixationTest < AuthTestCase
  PASSCODE = "test-secret-123"

  def setup
    super
    @original_passcode = HardenAuth.passcode
    HardenAuth.passcode = PASSCODE
  end

  def teardown
    HardenAuth.passcode = @original_passcode
  end

  def test_session_id_changes_after_authentication
    # Make a request to establish a session
    get "/"
    pre_auth_cookie = rack_mock_session.cookie_jar["rack.session"]
    assert pre_auth_cookie, "Should have a session cookie before auth"

    # Authenticate
    post "/auth", passcode: PASSCODE
    assert_equal 302, last_response.status

    post_auth_cookie = rack_mock_session.cookie_jar["rack.session"]
    assert post_auth_cookie, "Should have a session cookie after auth"

    refute_equal pre_auth_cookie, post_auth_cookie,
                 "Session ID must change after authentication (fixation protection)"
  end
end

# ── CORS Tests ──────────────────────────────────────────────

class CorsTest < AuthTestCase
  def test_no_cors_headers_by_default
    get "/"
    refute last_response.headers.key?("Access-Control-Allow-Origin"),
           "CORS headers should not be present without CORS_ORIGIN"
  end

  def test_cors_headers_when_origin_set
    original = CORS_ORIGIN
    silence_warnings { Object.const_set(:CORS_ORIGIN, "http://localhost:3000") }

    get "/"
    assert_equal "http://localhost:3000", last_response.headers["Access-Control-Allow-Origin"]
    assert_includes last_response.headers["Access-Control-Allow-Headers"], "X-Requested-With"
  ensure
    silence_warnings { Object.const_set(:CORS_ORIGIN, original) }
  end
end
