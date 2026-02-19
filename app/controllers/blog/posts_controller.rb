class Blog::PostsController < ApplicationController
  before_action :require_authentication, except: %i[ index show ]
  before_action :set_blog_post, only: %i[ show edit update destroy ]
  before_action :authorize_post_owner!, only: %i[ edit update destroy ]

  rate_limit to: 60, within: 1.minute, only: %i[ index show ]
  rate_limit to: 5, within: 1.minute, only: %i[ create update ]
  rate_limit to: 3, within: 1.minute, only: :destroy

  # GET /blog/posts or /blog/posts.json
  def index
    @blog_posts = Blog::Post.includes(:user).order(created_at: :desc).limit(25).offset(pagination_offset)
  end

  # GET /blog/posts/1 or /blog/posts/1.json
  def show
    @blog_comment = Blog::Comment.new(post: @blog_post)
  end

  # GET /blog/posts/new
  def new
    @blog_post = Blog::Post.new
  end

  # GET /blog/posts/1/edit
  def edit
  end

  # POST /blog/posts or /blog/posts.json
  def create
    @blog_post = Blog::Post.new(blog_post_params)
    @blog_post.user = current_user

    respond_to do |format|
      if @blog_post.save
        format.html { redirect_to @blog_post, notice: "Post was successfully created." }
        format.json { render :show, status: :created, location: @blog_post }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: { errors: sanitized_errors(@blog_post) }, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /blog/posts/1 or /blog/posts/1.json
  def update
    respond_to do |format|
      if @blog_post.update(blog_post_params)
        format.html { redirect_to @blog_post, notice: "Post was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @blog_post }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: { errors: sanitized_errors(@blog_post) }, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /blog/posts/1 or /blog/posts/1.json
  def destroy
    if @blog_post.destroy
      respond_to do |format|
        format.html { redirect_to blog_posts_path, notice: "Post was successfully destroyed.", status: :see_other }
        format.json { head :no_content }
      end
    else
      respond_to do |format|
        format.html { redirect_to @blog_post, alert: "Post could not be destroyed.", status: :see_other }
        format.json { render json: { error: "Post could not be destroyed." }, status: :unprocessable_entity }
      end
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_blog_post
      @blog_post = Blog::Post.includes(:user).find(params.expect(:id))
    end

    # Verify the current user owns the post before allowing mutations.
    def authorize_post_owner!
      unless @blog_post.user_id == current_user.id
        respond_to do |format|
          format.html { redirect_to @blog_post, alert: "You are not authorized to perform this action.", status: :see_other }
          format.json { render json: { error: "Forbidden" }, status: :forbidden }
        end
      end
    end

    # Only allow a list of trusted parameters through.
    def blog_post_params
      params.expect(blog_post: [ :title, :body, :topic ])
    end

    # Cap page depth to prevent large-OFFSET DoS against the database.
    # For larger datasets, consider keyset pagination (WHERE created_at < :cursor)
    # which performs in constant time regardless of page depth.
    def pagination_offset
      params.fetch(:page, 0).to_i.clamp(0, 400) * 25
    end

    # Map model errors to user-friendly messages without exposing internal
    # attribute names, validation rules, or schema details.
    def sanitized_errors(record)
      record.errors.map do |error|
        error.attribute.to_s.humanize
      end.uniq.map { |field| "#{field} is invalid" }
    end
end
