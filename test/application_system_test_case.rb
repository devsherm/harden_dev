require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]

  def sign_in_as_system(name, password: "password")
    visit new_core_session_path
    fill_in "Name", with: name
    fill_in "Password", with: password
    click_button "Sign in"
    assert_text "Signed in as #{name}"
  end
end
