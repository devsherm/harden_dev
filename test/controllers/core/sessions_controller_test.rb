require "test_helper"

class Core::SessionsControllerTest < ActionDispatch::IntegrationTest
  test "should get new" do
    get new_core_session_url
    assert_response :success
  end

  test "should sign in with valid credentials" do
    post core_session_url, params: { name: "Alice", password: "password" }
    assert_redirected_to root_path
    assert cookies[:session_id].present?
  end

  test "should reject invalid password" do
    post core_session_url, params: { name: "Alice", password: "wrong" }
    assert_response :unprocessable_entity
  end

  test "should reject nonexistent user" do
    post core_session_url, params: { name: "Nobody", password: "password" }
    assert_response :unprocessable_entity
  end

  test "should sign out" do
    post core_session_url, params: { name: "Alice", password: "password" }
    delete core_session_url
    assert_redirected_to new_core_session_path
  end
end
