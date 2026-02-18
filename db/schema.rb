# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_02_18_113451) do
  create_table "blog_comments", force: :cascade do |t|
    t.string "author"
    t.text "body"
    t.datetime "created_at", null: false
    t.string "liked_by_author"
    t.integer "post_id", null: false
    t.datetime "updated_at", null: false
    t.index ["post_id"], name: "index_blog_comments_on_post_id"
  end

  create_table "blog_posts", force: :cascade do |t|
    t.string "author"
    t.text "body"
    t.datetime "created_at", null: false
    t.string "title"
    t.string "topic"
    t.datetime "updated_at", null: false
  end

  add_foreign_key "blog_comments", "posts"
end
