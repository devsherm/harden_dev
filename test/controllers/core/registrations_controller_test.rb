require "test_helper"

class Core::RegistrationsControllerTest < ActionDispatch::IntegrationTest
  test "should get new" do
    get new_core_registration_url
    assert_response :success
  end

  test "should create user with valid params" do
    assert_difference("Core::User.count") do
      post core_registration_url, params: { core_user: { name: "Frank", password: "password", password_confirmation: "password" } }
    end
    assert_redirected_to root_path
    assert cookies[:session_id].present?
  end

  test "should reject duplicate name" do
    assert_no_difference("Core::User.count") do
      post core_registration_url, params: { core_user: { name: "Alice", password: "password", password_confirmation: "password" } }
    end
    assert_response :unprocessable_entity
  end

  test "should reject mismatched passwords" do
    assert_no_difference("Core::User.count") do
      post core_registration_url, params: { core_user: { name: "NewUser", password: "password", password_confirmation: "different" } }
    end
    assert_response :unprocessable_entity
  end
end
