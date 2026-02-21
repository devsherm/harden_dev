# frozen_string_literal: true

require_relative "test_helper"
require "json"

# StubHTTPResponse mimics Net::HTTP response objects for testing.
class StubHTTPResponse
  attr_reader :code, :body

  def initialize(code, body)
    @code = code.to_s
    @body = body
  end

  def is_a?(klass)
    return @code.to_i < 400 if klass == Net::HTTPSuccess
    super
  end
end

class ApiCallTest < PipelineTestCase
  TEST_API_KEY = "test-api-key-12345"

  def setup
    super
    @pipeline.instance_variable_set(:@api_key, TEST_API_KEY)
    @captured_request = nil
    @stub_response = nil
  end

  # ── Successful API call ────────────────────────────────────

  def test_api_call_posts_to_messages_endpoint
    with_stub_http(success_response([text_block("Hello, world!")])) do
      result = @pipeline.send(:api_call, "Hello?")
      assert_equal "Hello, world!", result
    end

    assert_equal "claude-sonnet-4-6", @captured_request[:body]["model"]
    assert_equal 4096, @captured_request[:body]["max_tokens"]
    assert_equal [{ "role" => "user", "content" => "Hello?" }], @captured_request[:body]["messages"]
  end

  def test_api_call_includes_web_search_tool
    with_stub_http(success_response([text_block("Result")])) do
      @pipeline.send(:api_call, "Search for something")
    end

    tools = @captured_request[:body]["tools"]
    refute_nil tools
    assert_equal 1, tools.length
    assert_equal "web_search_20250305", tools.first["type"]
    assert_equal "web_search", tools.first["name"]
    assert_equal 10, tools.first["max_uses"]
  end

  def test_api_call_sends_api_key_header
    with_stub_http(success_response([text_block("OK")])) do
      @pipeline.send(:api_call, "Test")
    end

    assert_equal TEST_API_KEY, @captured_request[:headers]["x-api-key"]
  end

  def test_api_call_sends_anthropic_version_header
    with_stub_http(success_response([text_block("OK")])) do
      @pipeline.send(:api_call, "Test")
    end

    assert_equal "2023-06-01", @captured_request[:headers]["anthropic-version"]
  end

  def test_api_call_uses_default_model
    with_stub_http(success_response([text_block("OK")])) do
      @pipeline.send(:api_call, "Test")
    end

    assert_equal "claude-sonnet-4-6", @captured_request[:body]["model"]
  end

  def test_api_call_accepts_custom_model
    with_stub_http(success_response([text_block("OK")])) do
      @pipeline.send(:api_call, "Test", model: "claude-opus-4-6")
    end

    assert_equal "claude-opus-4-6", @captured_request[:body]["model"]
  end

  # ── Response text extraction ──────────────────────────────

  def test_api_call_extracts_text_blocks_only
    with_stub_http(success_response([
      text_block("First text block"),
      { "type" => "server_tool_use", "id" => "123", "name" => "web_search", "input" => {} },
      { "type" => "web_search_tool_result", "tool_use_id" => "123", "content" => [] },
      text_block("Second text block")
    ])) do
      result = @pipeline.send(:api_call, "Search query")
      assert_equal "First text block\nSecond text block", result
    end
  end

  def test_api_call_discards_server_tool_use_blocks
    with_stub_http(success_response([
      { "type" => "server_tool_use", "id" => "abc", "name" => "web_search", "input" => { "query" => "test" } }
    ])) do
      result = @pipeline.send(:api_call, "Search")
      assert_equal "", result
    end
  end

  def test_api_call_discards_web_search_tool_result_blocks
    with_stub_http(success_response([
      { "type" => "web_search_tool_result", "tool_use_id" => "abc", "content" => [] }
    ])) do
      result = @pipeline.send(:api_call, "Search")
      assert_equal "", result
    end
  end

  def test_api_call_concatenates_multiple_text_blocks_with_newlines
    with_stub_http(success_response([
      text_block("Line one"),
      text_block("Line two"),
      text_block("Line three")
    ])) do
      result = @pipeline.send(:api_call, "Generate text")
      assert_equal "Line one\nLine two\nLine three", result
    end
  end

  def test_api_call_returns_empty_string_for_no_text_blocks
    with_stub_http(success_response([])) do
      result = @pipeline.send(:api_call, "Test")
      assert_equal "", result
    end
  end

  # ── Error handling ─────────────────────────────────────────

  def test_api_call_raises_on_http_error_response
    with_stub_http(error_response(401, '{"error": {"type": "authentication_error", "message": "Invalid API key"}}')) do
      err = assert_raises(RuntimeError) do
        @pipeline.send(:api_call, "Test")
      end
      assert_match(/Claude API error 401/, err.message)
    end
  end

  def test_api_call_raises_on_server_error
    with_stub_http(error_response(500, '{"error": {"type": "internal_server_error", "message": "Server error"}}')) do
      err = assert_raises(RuntimeError) do
        @pipeline.send(:api_call, "Test")
      end
      assert_match(/Claude API error 500/, err.message)
    end
  end

  # ── API semaphore concurrency limiting ────────────────────

  def test_api_semaphore_initialized
    semaphore = @pipeline.instance_variable_get(:@api_semaphore)
    refute_nil semaphore
    assert_instance_of Mutex, semaphore
  end

  def test_api_slots_initialized
    slots = @pipeline.instance_variable_get(:@api_slots)
    refute_nil slots
    assert_instance_of ConditionVariable, slots
  end

  def test_api_active_starts_at_zero
    assert_equal 0, @pipeline.instance_variable_get(:@api_active)
  end

  def test_acquire_api_slot_increments_active_count
    @pipeline.send(:acquire_api_slot)
    assert_equal 1, @pipeline.instance_variable_get(:@api_active)
  ensure
    @pipeline.send(:release_api_slot)
  end

  def test_release_api_slot_decrements_active_count
    @pipeline.send(:acquire_api_slot)
    @pipeline.send(:release_api_slot)
    assert_equal 0, @pipeline.instance_variable_get(:@api_active)
  end

  def test_can_acquire_up_to_max_api_slots
    original_max = Pipeline::MAX_API_CONCURRENCY
    Pipeline.send(:remove_const, :MAX_API_CONCURRENCY)
    Pipeline.const_set(:MAX_API_CONCURRENCY, 3)

    3.times { @pipeline.send(:acquire_api_slot) }
    assert_equal 3, @pipeline.instance_variable_get(:@api_active)
  ensure
    Pipeline.send(:remove_const, :MAX_API_CONCURRENCY)
    Pipeline.const_set(:MAX_API_CONCURRENCY, original_max)
    active = @pipeline.instance_variable_get(:@api_active)
    active.times { @pipeline.send(:release_api_slot) }
  end

  def test_slot_beyond_max_blocks_until_released
    original_max = Pipeline::MAX_API_CONCURRENCY
    Pipeline.send(:remove_const, :MAX_API_CONCURRENCY)
    Pipeline.const_set(:MAX_API_CONCURRENCY, 2)

    original_report = Thread.report_on_exception
    Thread.report_on_exception = false

    2.times { @pipeline.send(:acquire_api_slot) }

    acquired = false
    blocker = Thread.new do
      @pipeline.send(:acquire_api_slot)
      acquired = true
    end

    sleep 0.1
    refute acquired, "Thread should be blocked waiting for API slot"

    @pipeline.send(:release_api_slot)
    blocker.join(3)

    assert acquired, "Thread should have acquired slot after release"
  ensure
    Thread.report_on_exception = original_report
    Pipeline.send(:remove_const, :MAX_API_CONCURRENCY)
    Pipeline.const_set(:MAX_API_CONCURRENCY, original_max)
    active = @pipeline.instance_variable_get(:@api_active)
    active.times { @pipeline.send(:release_api_slot) }
  end

  def test_api_slot_released_on_success
    with_stub_http(success_response([text_block("OK")])) do
      @pipeline.send(:api_call, "Test")
    end

    assert_equal 0, @pipeline.instance_variable_get(:@api_active)
  end

  def test_api_slot_released_on_error
    with_stub_http(error_response(500, '{"error": "server error"}')) do
      assert_raises(RuntimeError) { @pipeline.send(:api_call, "Test") }
    end

    assert_equal 0, @pipeline.instance_variable_get(:@api_active)
  end

  # ── MAX_API_CONCURRENCY constant ──────────────────────────

  def test_max_api_concurrency_constant_exists
    assert_equal 20, Pipeline::MAX_API_CONCURRENCY
  end

  private

  # Intercepts Net::HTTP.new to return a stub HTTP object that records
  # requests and returns the given response. Captures request details in
  # @captured_request for assertions.
  def with_stub_http(response)
    captured = { body: nil, headers: {} }
    test_obj = self

    http_stub = Object.new
    http_stub.define_singleton_method(:use_ssl=) { |_| }
    http_stub.define_singleton_method(:request) do |req|
      captured[:body] = JSON.parse(req.body)
      captured[:headers] = {
        "x-api-key" => req["x-api-key"],
        "anthropic-version" => req["anthropic-version"],
        "content-type" => req["content-type"]
      }
      response
    end

    original_new = Net::HTTP.singleton_method(:new)
    Net::HTTP.define_singleton_method(:new) { |*_| http_stub }

    yield
  ensure
    Net::HTTP.define_singleton_method(:new) { |*args| original_new.call(*args) }
    @captured_request = captured
  end

  def text_block(text)
    { "type" => "text", "text" => text }
  end

  def success_response(content_blocks)
    StubHTTPResponse.new(200, { "content" => content_blocks }.to_json)
  end

  def error_response(code, body)
    StubHTTPResponse.new(code, body)
  end
end
