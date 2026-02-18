require "test_helper"

class Blog::PostsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @blog_post = blog_posts(:one)
  end

  test "should get index" do
    get blog_posts_url
    assert_response :success
  end

  test "should get new" do
    get new_blog_post_url
    assert_response :success
  end

  test "should create blog_post" do
    assert_difference("Blog::Post.count") do
      post blog_posts_url, params: { blog_post: { author: @blog_post.author, body: @blog_post.body, title: @blog_post.title, topic: @blog_post.topic } }
    end

    assert_redirected_to blog_post_url(Blog::Post.last)
  end

  test "should show blog_post" do
    get blog_post_url(@blog_post)
    assert_response :success
  end

  test "should get edit" do
    get edit_blog_post_url(@blog_post)
    assert_response :success
  end

  test "should update blog_post" do
    patch blog_post_url(@blog_post), params: { blog_post: { author: @blog_post.author, body: @blog_post.body, title: @blog_post.title, topic: @blog_post.topic } }
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
      post blog_posts_url, params: { blog_post: { author: "a", body: "b", title: "", topic: "" } }
    end
    assert_response :unprocessable_entity
  end

  test "should not update post with blank title" do
    patch blog_post_url(@blog_post), params: { blog_post: { title: "" } }
    assert_response :unprocessable_entity
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
end
