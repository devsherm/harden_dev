class Blog::Post < ApplicationRecord
  belongs_to :user, class_name: "Core::User"
  has_many :comments, dependent: :destroy

  validates :title, presence: true, length: { maximum: 255 }
  validates :body, presence: true, length: { maximum: 50_000 }
  validates :topic, length: { maximum: 100 }
end
