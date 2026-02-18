post1 = Blog::Post.create!(
  title: "Getting Started with Rails",
  body: "Rails is a great framework for building web applications quickly. It follows convention over configuration, making it easy to get started.",
  author: "Alice",
  topic: "Rails"
)

post2 = Blog::Post.create!(
  title: "Design Principles for Modern Web Apps",
  body: "Good design starts with understanding your users. In this post, we explore key principles for creating intuitive interfaces.",
  author: "Bob",
  topic: "Design"
)

post3 = Blog::Post.create!(
  title: "My Weekend Project",
  body: "This weekend I built a small CLI tool in Ruby. It was a fun exercise and I learned a lot about argument parsing.",
  author: "Charlie"
)

post4 = Blog::Post.create!(
  title: "Why Testing Matters",
  body: "Automated tests give you confidence that your code works as expected. They also serve as living documentation for your codebase.",
  author: "Alice",
  topic: "Testing"
)

Blog::Comment.create!(post: post1, author: "Bob", body: "Great introduction! This helped me get started.")
Blog::Comment.create!(post: post1, author: "Charlie", body: "I wish I had read this when I first started learning Rails.")
Blog::Comment.create!(post: post1, author: "Diana", body: "Could you write a follow-up on Active Record?")
Blog::Comment.create!(post: post2, author: "Alice", body: "These principles are spot on. I especially agree about user empathy.")
Blog::Comment.create!(post: post2, author: "Eve", body: "Do you have any book recommendations on this topic?")
Blog::Comment.create!(post: post3, author: "Bob", body: "Sounds like a fun project! Mind sharing the repo?")
Blog::Comment.create!(post: post4, author: "Diana", body: "Testing has saved me so many times. Great post!")
Blog::Comment.create!(post: post4, author: "Charlie", body: "What testing framework do you recommend for beginners?")
