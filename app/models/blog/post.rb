class Blog::Post < ApplicationRecord
  has_many :comments, dependent: :destroy

  validates :title, presence: true, length: { maximum: 255 }
  validates :body, presence: true, length: { maximum: 50_000 }
  validates :author, presence: true, length: { maximum: 100 }
end
