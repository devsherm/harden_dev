class Blog::Post < ApplicationRecord
  has_many :comments, dependent: :destroy

  validates :title, :body, :author, presence: true
end
