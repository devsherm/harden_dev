class Core::RegistrationsController < ApplicationController
  rate_limit to: 5, within: 1.minute, only: :create

  def new
    @user = Core::User.new
  end

  def create
    @user = Core::User.new(registration_params)

    if @user.save
      start_session(@user)
      redirect_to root_path, notice: "Account created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def registration_params
    params.expect(core_user: [ :name, :password, :password_confirmation ])
  end
end
