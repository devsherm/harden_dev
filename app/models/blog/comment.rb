class Blog::Comment < ApplicationRecord
  belongs_to :post
  belongs_to :user, class_name: "Core::User"

  enum :like_status, { unset: "unset", liked: "liked" }, default: :unset

  validates :body, presence: true, length: { maximum: 10_000 }
end
