module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :resume_session
    helper_method :current_user, :signed_in?
  end

  private

  def resume_session
    if (session_id = cookies.signed[:session_id])
      Current.session = Core::Session.find_by(id: session_id)
    end
  end

  def require_authentication
    redirect_to new_core_session_path, alert: "Please sign in to continue." unless Current.session
  end

  def current_user
    Current.session&.user
  end

  def signed_in?
    Current.session.present?
  end

  def start_session(user)
    session = user.sessions.create!(
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    )
    Current.session = session
    cookies.signed[:session_id] = {
      value: session.id,
      httponly: true,
      same_site: :lax,
      expires: 2.weeks.from_now
    }
  end

  def end_session
    Current.session&.destroy
    cookies.delete(:session_id)
  end
end
