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

ActiveRecord::Schema[8.1].define(version: 2026_02_19_200000) do
  create_table "blog_comments", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.string "like_status", default: "unset", null: false
    t.integer "post_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["post_id"], name: "index_blog_comments_on_post_id"
    t.index ["user_id"], name: "index_blog_comments_on_user_id"
  end

  create_table "blog_posts", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.string "title"
    t.string "topic"
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["user_id"], name: "index_blog_posts_on_user_id"
  end

  create_table "core_sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
  end

  create_table "core_users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_core_users_on_name", unique: true
  end

  add_foreign_key "blog_comments", "blog_posts", column: "post_id", on_delete: :cascade
  add_foreign_key "blog_comments", "core_users", column: "user_id", on_delete: :cascade
  add_foreign_key "blog_posts", "core_users", column: "user_id", on_delete: :cascade
  add_foreign_key "core_sessions", "core_users", column: "user_id", on_delete: :cascade
end
