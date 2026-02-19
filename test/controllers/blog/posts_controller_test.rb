require "test_helper"

class Blog::PostsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @blog_post = blog_posts(:one)
    sign_in_as(core_users(:alice))
  end

  # === Public access (no auth required) ===

  test "should get index" do
    get blog_posts_url
    assert_response :success
  end

  test "should show blog_post" do
    get blog_post_url(@blog_post)
    assert_response :success
  end

  test "should return JSON index" do
    get blog_posts_url(format: :json)
    assert_response :success
    assert_equal "application/json; charset=utf-8", @response.content_type
  end

  test "root redirects to posts index" do
    get root_url
    assert_redirected_to blog_posts_url
  end

  # === Authenticated actions ===

  test "should get new" do
    get new_blog_post_url
    assert_response :success
  end

  test "should create blog_post" do
    assert_difference("Blog::Post.count") do
      post blog_posts_url, params: { blog_post: { body: "New body", title: "New title", topic: "Rails" } }
    end
    assert_equal core_users(:alice).id, Blog::Post.last.user_id
    assert_redirected_to blog_post_url(Blog::Post.last)
  end

  test "should get edit" do
    get edit_blog_post_url(@blog_post)
    assert_response :success
  end

  test "should update blog_post" do
    patch blog_post_url(@blog_post), params: { blog_post: { body: @blog_post.body, title: @blog_post.title, topic: @blog_post.topic } }
    assert_redirected_to blog_post_url(@blog_post)
  end

  test "should destroy blog_post" do
    assert_difference("Blog::Post.count", -1) do
      delete blog_post_url(@blog_post)
    end
    assert_redirected_to blog_posts_url
  end

  test "should not create post with blank title" do
    assert_no_difference("Blog::Post.count") do
      post blog_posts_url, params: { blog_post: { body: "b", title: "", topic: "" } }
    end
    assert_response :unprocessable_entity
  end

  test "should not update post with blank title" do
    patch blog_post_url(@blog_post), params: { blog_post: { title: "" } }
    assert_response :unprocessable_entity
  end

  # === Unauthenticated access redirects to sign-in ===

  test "unauthenticated user is redirected from new" do
    reset!
    get new_blog_post_url
    assert_redirected_to new_core_session_path
  end

  test "unauthenticated user is redirected from create" do
    reset!
    assert_no_difference("Blog::Post.count") do
      post blog_posts_url, params: { blog_post: { body: "b", title: "t", topic: "" } }
    end
    assert_redirected_to new_core_session_path
  end

  test "unauthenticated user is redirected from edit" do
    reset!
    get edit_blog_post_url(@blog_post)
    assert_redirected_to new_core_session_path
  end

  test "unauthenticated user is redirected from update" do
    reset!
    patch blog_post_url(@blog_post), params: { blog_post: { title: "New" } }
    assert_redirected_to new_core_session_path
  end

  test "unauthenticated user is redirected from destroy" do
    reset!
    assert_no_difference("Blog::Post.count") do
      delete blog_post_url(@blog_post)
    end
    assert_redirected_to new_core_session_path
  end

  # === Authorization: non-owner cannot edit/update/destroy ===

  test "non-owner is forbidden from edit" do
    reset!
    sign_in_as(core_users(:bob))
    get edit_blog_post_url(@blog_post)
    assert_redirected_to blog_post_url(@blog_post)
  end

  test "non-owner is forbidden from update" do
    reset!
    sign_in_as(core_users(:bob))
    patch blog_post_url(@blog_post), params: { blog_post: { title: "Hacked" } }
    assert_redirected_to blog_post_url(@blog_post)
  end

  test "non-owner is forbidden from destroy" do
    reset!
    sign_in_as(core_users(:bob))
    assert_no_difference("Blog::Post.count") do
      delete blog_post_url(@blog_post)
    end
    assert_redirected_to blog_post_url(@blog_post)
  end
end
