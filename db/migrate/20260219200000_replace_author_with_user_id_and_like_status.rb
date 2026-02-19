class ReplaceAuthorWithUserIdAndLikeStatus < ActiveRecord::Migration[8.1]
  def change
    add_column :blog_posts, :user_id, :integer
    add_index :blog_posts, :user_id
    add_foreign_key :blog_posts, :core_users, column: :user_id, on_delete: :cascade

    add_column :blog_comments, :user_id, :integer
    add_index :blog_comments, :user_id
    add_foreign_key :blog_comments, :core_users, column: :user_id, on_delete: :cascade

    add_column :blog_comments, :like_status, :string, default: "unset", null: false

    remove_column :blog_posts, :author, :string
    remove_column :blog_comments, :author, :string
    remove_column :blog_comments, :liked_by_author, :string
  end
end
