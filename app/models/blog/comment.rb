class Blog::Comment < ApplicationRecord
  belongs_to :post
  validates :author, presence: true, length: { maximum: 100 }
  validates :body, presence: true, length: { maximum: 10_000 }
end
