class Core::SessionsController < ApplicationController
  rate_limit to: 10, within: 1.minute, only: :create

  def new
  end

  def create
    user = Core::User.find_by(name: params[:name])

    if user&.authenticate(params[:password])
      start_session(user)
      redirect_to root_path, notice: "Signed in successfully."
    else
      flash.now[:alert] = "Invalid name or password."
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    end_session
    redirect_to new_core_session_path, notice: "Signed out successfully."
  end
end
