class Blog::Post < ApplicationRecord
  belongs_to :user, class_name: "Core::User"
  has_many :comments, dependent: :destroy

  enum :topic, {
    excavation: "excavation",
    concrete: "concrete",
    framing: "framing",
    roofing: "roofing",
    demolition: "demolition",
    heavy_equipment: "heavy_equipment",
    safety_fails: "safety_fails",
    inspections: "inspections",
    job_site_stories: "job_site_stories"
  }

  validates :title, presence: true, length: { maximum: 255 }
  validates :body, presence: true, length: { maximum: 50_000 }
  validates :topic, inclusion: { in: topics.keys }, allow_blank: true
end
