json.extract! blog_comment, :id, :post_id, :body, :author, :liked_by_author, :created_at, :updated_at
json.url blog_comment_url(blog_comment, format: :json)
