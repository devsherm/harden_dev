class CreateCoreUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :core_users do |t|
      t.string :name, null: false
      t.string :password_digest, null: false

      t.timestamps
    end

    add_index :core_users, :name, unique: true
  end
end
