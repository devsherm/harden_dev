users = %w[Alice Bob Charlie Diana Eve].each_with_object({}) do |name, hash|
  hash[name] = Core::User.create!(name: name, password: "password", password_confirmation: "password")
end

post1 = Blog::Post.create!(
  title: "We Poured 40 Yards of Concrete in the Rain",
  body: "The forecast said partly cloudy. The forecast lied. Here's how we saved a foundation pour when the sky opened up at 7 AM.",
  user: users["Alice"],
  topic: :concrete
)

post2 = Blog::Post.create!(
  title: "That Time the Excavator Sank Into the Mud",
  body: "Lesson learned: never trust a site survey from 2003. We spent two days extracting a 30-ton excavator from what turned out to be a buried creek bed.",
  user: users["Bob"],
  topic: :heavy_equipment
)

post3 = Blog::Post.create!(
  title: "My Weekend Shed Build",
  body: "Took a break from commercial jobs and framed a 12x16 shed for my neighbor. No permits, no inspectors, no stress. Just vibes and a nail gun.",
  user: users["Charlie"]
)

post4 = Blog::Post.create!(
  title: "OSHA Would Like a Word: Worst Ladder Setups I've Seen",
  body: "A leaning extension ladder on a pile of loose bricks, a step ladder on a scaffold plank, and the legendary 'two ladders duct-taped together'. Let's talk about why people do this and how to stop it.",
  user: users["Alice"],
  topic: :safety_fails
)

Blog::Comment.create!(post: post1, user: users["Bob"], body: "Been there. We once had a pump truck break down mid-pour in a thunderstorm. Good times.")
Blog::Comment.create!(post: post1, user: users["Charlie"], body: "Pro tip: keep tarps on the truck, not in the trailer.")
Blog::Comment.create!(post: post1, user: users["Diana"], body: "40 yards?! How many trucks was that?")
Blog::Comment.create!(post: post2, user: users["Alice"], body: "This is why I always walk the site myself before bringing in heavy iron.")
Blog::Comment.create!(post: post2, user: users["Eve"], body: "How deep was it stuck? We had a similar situation with a dozer last spring.")
Blog::Comment.create!(post: post3, user: users["Bob"], body: "No permits, no inspectors, no stress — the dream.")
Blog::Comment.create!(post: post4, user: users["Diana"], body: "I once saw a guy standing on a bucket on top of a ladder. On a slope.")
Blog::Comment.create!(post: post4, user: users["Charlie"], body: "The duct-taped ladders story can't be real... right?")
