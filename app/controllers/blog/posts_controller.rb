class Blog::PostsController < ApplicationController
  # before_action :require_authentication, except: %i[ index show ]
  before_action :set_blog_post, only: %i[ show edit update destroy ]
  # before_action :authorize_post_owner!, only: %i[ edit update destroy ]

  rate_limit to: 5, within: 1.minute, only: %i[ create update ]
  rate_limit to: 3, within: 1.minute, only: :destroy

  # GET /blog/posts or /blog/posts.json
  def index
    @blog_posts = Blog::Post.order(created_at: :desc).limit(25).offset(pagination_offset)
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

    respond_to do |format|
      if @blog_post.save
        format.html { redirect_to @blog_post, notice: "Post was successfully created." }
        format.json { render :show, status: :created, location: @blog_post }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: { errors: @blog_post.errors.full_messages }, status: :unprocessable_entity }
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
        format.json { render json: { errors: @blog_post.errors.full_messages }, status: :unprocessable_entity }
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
      @blog_post = Blog::Post.find(params.expect(:id))
    end

    # Verify the current user owns the post before allowing mutations.
    def authorize_post_owner!
      unless @blog_post.author == current_user.name
        respond_to do |format|
          format.html { redirect_to @blog_post, alert: "You are not authorized to perform this action.", status: :see_other }
          format.json { render json: { error: "Forbidden" }, status: :forbidden }
        end
      end
    end

    # Only allow a list of trusted parameters through.
    def blog_post_params
      params.expect(blog_post: [ :title, :body, :topic, :author ])
    end

    def pagination_offset
      [ params.fetch(:page, 0).to_i, 0 ].max * 25
    end
end
