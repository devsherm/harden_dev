class Blog::CommentsController < ApplicationController
  rate_limit to: 5, within: 1.minute, only: :create
  rate_limit to: 10, within: 1.minute, only: :toggle_like
  before_action :set_blog_comment, only: %i[ edit update destroy ]

  # GET /blog/comments or /blog/comments.json
  def index
    page = [ params.fetch(:page, 1).to_i, 1 ].max
    @blog_comments = Blog::Comment.includes(:post).order(created_at: :desc).limit(25).offset((page - 1) * 25)
  end

  # GET /blog/comments/new
  def new
    @blog_comment = Blog::Comment.new
  end

  # GET /blog/comments/1/edit
  def edit
  end

  # POST /blog/posts/:post_id/comments
  def create
    @blog_post = Blog::Post.find(params.expect(:post_id))
    @blog_comment = @blog_post.comments.build(blog_comment_params)

    respond_to do |format|
      if @blog_comment.save
        format.html { redirect_to blog_post_path(@blog_post), notice: "Comment was successfully created." }
        format.json { render :show, status: :created, location: @blog_comment }
      else
        format.html { render "blog/posts/show", status: :unprocessable_entity }
        format.json { render json: { errors: @blog_comment.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /blog/comments/1 or /blog/comments/1.json
  def update
    respond_to do |format|
      if @blog_comment.update(blog_comment_params)
        format.html { redirect_to blog_post_path(@blog_comment.post), notice: "Comment was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @blog_comment }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: { errors: @blog_comment.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  def toggle_like
    @blog_comment = Blog::Comment.find(params.expect(:id))
    if @blog_comment.liked_by_author.present?
      @blog_comment.update(liked_by_author: nil)
    else
      @blog_comment.update(liked_by_author: @blog_comment.post.author)
    end

    respond_to do |format|
      format.html { redirect_to blog_post_path(@blog_comment.post), status: :see_other }
      format.json { render :show, status: :ok, location: @blog_comment }
    end
  end

  # DELETE /blog/comments/1 or /blog/comments/1.json
  def destroy
    @blog_comment.destroy!

    respond_to do |format|
      format.html { redirect_to blog_post_path(@blog_comment.post), notice: "Comment was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_blog_comment
      @blog_comment = Blog::Comment.find(params.expect(:id))
    end

    # Only allow a list of trusted parameters through.
    def blog_comment_params
      params.expect(blog_comment: [ :body, :author ])
    end
end
