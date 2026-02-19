class CreateCoreSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :core_sessions do |t|
      t.integer :user_id, null: false
      t.string :ip_address
      t.string :user_agent

      t.timestamps
    end

    add_foreign_key :core_sessions, :core_users, column: :user_id, on_delete: :cascade
  end
end
