json.extract! blog_post, :id, :title, :body, :topic, :created_at, :updated_at
json.author blog_post.user.name
json.url blog_post_url(blog_post, format: :json)
