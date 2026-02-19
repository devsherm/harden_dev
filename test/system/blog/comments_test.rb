require "application_system_test_case"

class Blog::CommentsTest < ApplicationSystemTestCase
  test "like toggle sets like_status to liked" do
    sign_in_as_system("Alice")
    post = blog_posts(:one)
    comment = blog_comments(:one)

    visit blog_post_url(post)
    within "#blog_comment_#{comment.id}" do
      click_on "Like"
    end

    assert_text "Liked by #{post.user.name}"
  end

  test "unlike toggle clears like_status" do
    sign_in_as_system("Alice")
    post = blog_posts(:one)
    comment = blog_comments(:one)
    comment.liked!

    visit blog_post_url(post)
    within "#blog_comment_#{comment.id}" do
      click_on "Unlike"
    end

    assert_no_text "Liked by #{post.user.name}"
  end

  test "flash notice after comment create" do
    sign_in_as_system("Alice")
    post = blog_posts(:one)
    visit blog_post_url(post)
    fill_in "Body", with: "A test comment"
    click_on "Post comment"
    assert_text "Comment was successfully created."
  end

  test "validation errors on inline comment create with blank body" do
    sign_in_as_system("Alice")
    post = blog_posts(:one)
    visit blog_post_url(post)
    click_on "Post comment"
    assert_text "Body can't be blank"
  end

  test "comment edit page has back to post link" do
    sign_in_as_system("Charlie")
    comment = blog_comments(:one)
    visit edit_blog_comment_url(comment)
    assert_selector "a[href='#{blog_post_path(comment.post)}']", text: "Back to post"
  end
end
