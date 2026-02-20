require "minitest/autorun"
require "rack/test"
require "tmpdir"
require "fileutils"

# Prevent $pipeline.discover_controllers from running during require
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
end

class AuthDisabledTest < AuthTestCase
  def setup
    super
    @original = HARDEN_PASSCODE
    silence_warnings { Object.const_set(:HARDEN_PASSCODE, nil) }
  end

  def teardown
    silence_warnings { Object.const_set(:HARDEN_PASSCODE, @original) }
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

  private

  def silence_warnings
    old_verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = old_verbose
  end
end

class AuthEnabledTest < AuthTestCase
  PASSCODE = "test-secret-123"

  def setup
    super
    @original = HARDEN_PASSCODE
    silence_warnings { Object.const_set(:HARDEN_PASSCODE, PASSCODE) }
  end

  def teardown
    silence_warnings { Object.const_set(:HARDEN_PASSCODE, @original) }
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

  def test_options_is_not_blocked
    options "/pipeline/status"
    assert_equal 200, last_response.status
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

    # Log out
    post "/auth/logout"
    assert_equal 302, last_response.status

    # Should be locked out again
    get "/pipeline/status"
    assert_equal 401, last_response.status
  end

  def test_sse_endpoint_returns_401
    get "/events"
    assert_equal 401, last_response.status
  end

  private

  def silence_warnings
    old_verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = old_verbose
  end
end
