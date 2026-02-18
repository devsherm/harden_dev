class CreateBlogComments < ActiveRecord::Migration[8.1]
  def change
    create_table :blog_comments do |t|
      t.references :post, null: false, foreign_key: true
      t.text :body
      t.string :author
      t.string :liked_by_author

      t.timestamps
    end
  end
end
