class FixBlogCommentsForeignKey < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :blog_comments, :posts if foreign_key_exists?(:blog_comments, :posts)
    add_foreign_key :blog_comments, :blog_posts, column: :post_id, on_delete: :cascade
  end
end
