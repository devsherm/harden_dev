class Blog::Comment < ApplicationRecord
  belongs_to :post
  validates :author, :body, presence: true
end
