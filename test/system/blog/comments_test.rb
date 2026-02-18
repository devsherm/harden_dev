require "application_system_test_case"

class Blog::CommentsTest < ApplicationSystemTestCase
  test "like toggle sets liked_by_author" do
    post = blog_posts(:one)
    comment = blog_comments(:one)

    visit blog_post_url(post)
    within "#blog_comment_#{comment.id}" do
      click_on "Like"
    end

    assert_text "Liked by #{post.author}"
  end

  test "unlike toggle clears liked_by_author" do
    post = blog_posts(:one)
    comment = blog_comments(:one)
    comment.update!(liked_by_author: post.author)

    visit blog_post_url(post)
    within "#blog_comment_#{comment.id}" do
      click_on "Unlike"
    end

    assert_no_text "Liked by #{post.author}"
  end

  test "flash notice after comment create" do
    post = blog_posts(:one)
    visit blog_post_url(post)
    fill_in "Author", with: "TestCommenter"
    fill_in "Body", with: "A test comment"
    click_on "Post comment"
    assert_text "Comment was successfully created."
  end

  test "validation errors on inline comment create with blank body" do
    post = blog_posts(:one)
    visit blog_post_url(post)
    fill_in "Author", with: "Someone"
    click_on "Post comment"
    assert_text "Body can't be blank"
  end

  test "comment edit page has back to post link" do
    comment = blog_comments(:one)
    visit edit_blog_comment_url(comment)
    assert_selector "a[href='#{blog_post_path(comment.post)}']", text: "Back to post"
  end
end
