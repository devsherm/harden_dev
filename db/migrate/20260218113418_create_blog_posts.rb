class CreateBlogPosts < ActiveRecord::Migration[8.1]
  def change
    create_table :blog_posts do |t|
      t.string :title
      t.text :body
      t.string :topic
      t.string :author

      t.timestamps
    end
  end
end
