class Core::User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :posts, class_name: "Blog::Post", dependent: :destroy
  has_many :comments, class_name: "Blog::Comment", dependent: :destroy

  validates :name, presence: true, uniqueness: true, length: { maximum: 100 }

  normalizes :name, with: -> { _1.strip }
end
