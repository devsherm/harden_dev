json.extract! blog_comment, :id, :post_id, :body, :like_status, :created_at, :updated_at
json.author blog_comment.user.name
json.url blog_comment_url(blog_comment, format: :json)
