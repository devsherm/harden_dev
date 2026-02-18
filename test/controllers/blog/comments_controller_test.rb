require "test_helper"

class Blog::CommentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @blog_comment = blog_comments(:one)
    @blog_post = @blog_comment.post
  end

  test "should get index" do
    get blog_comments_url
    assert_response :success
  end

  test "should get new" do
    get new_blog_comment_url
    assert_response :success
  end

  test "should create blog_comment" do
    assert_difference("Blog::Comment.count") do
      post blog_post_comments_url(@blog_post), params: { blog_comment: { author: @blog_comment.author, body: @blog_comment.body } }
    end

    assert_redirected_to blog_post_url(@blog_post)
  end

  test "should get edit" do
    get edit_blog_comment_url(@blog_comment)
    assert_response :success
  end

  test "should update blog_comment" do
    patch blog_comment_url(@blog_comment), params: { blog_comment: { author: @blog_comment.author, body: @blog_comment.body } }
    assert_redirected_to blog_post_url(@blog_comment.post)
  end

  test "should destroy blog_comment" do
    post_for_redirect = @blog_comment.post
    assert_difference("Blog::Comment.count", -1) do
      delete blog_comment_url(@blog_comment)
    end

    assert_redirected_to blog_post_url(post_for_redirect)
  end

  test "should not create comment with blank body" do
    assert_no_difference("Blog::Comment.count") do
      post blog_post_comments_url(@blog_post), params: { blog_comment: { author: "a", body: "" } }
    end
    assert_response :unprocessable_entity
  end

  test "should not update comment with blank body" do
    patch blog_comment_url(@blog_comment), params: { blog_comment: { body: "" } }
    assert_response :unprocessable_entity
  end

  test "should toggle like on comment" do
    @blog_comment.update!(liked_by_author: nil)
    patch toggle_like_blog_comment_url(@blog_comment)
    assert_redirected_to blog_post_url(@blog_post)
    @blog_comment.reload
    assert_equal @blog_post.author, @blog_comment.liked_by_author
  end

  test "should toggle unlike on comment" do
    @blog_comment.update!(liked_by_author: @blog_post.author)
    patch toggle_like_blog_comment_url(@blog_comment)
    assert_redirected_to blog_post_url(@blog_post)
    @blog_comment.reload
    assert_nil @blog_comment.liked_by_author
  end
end
