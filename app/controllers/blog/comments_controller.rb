class Blog::CommentsController < ApplicationController
  before_action :set_blog_comment, only: %i[ show edit update destroy ]

  # GET /blog/comments or /blog/comments.json
  def index
    @blog_comments = Blog::Comment.all
  end

  # GET /blog/comments/1 or /blog/comments/1.json
  def show
  end

  # GET /blog/comments/new
  def new
    @blog_comment = Blog::Comment.new
  end

  # GET /blog/comments/1/edit
  def edit
  end

  # POST /blog/comments or /blog/comments.json
  def create
    @blog_comment = Blog::Comment.new(blog_comment_params)

    respond_to do |format|
      if @blog_comment.save
        format.html { redirect_to @blog_comment, notice: "Comment was successfully created." }
        format.json { render :show, status: :created, location: @blog_comment }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @blog_comment.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /blog/comments/1 or /blog/comments/1.json
  def update
    respond_to do |format|
      if @blog_comment.update(blog_comment_params)
        format.html { redirect_to @blog_comment, notice: "Comment was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @blog_comment }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @blog_comment.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /blog/comments/1 or /blog/comments/1.json
  def destroy
    @blog_comment.destroy!

    respond_to do |format|
      format.html { redirect_to blog_comments_path, notice: "Comment was successfully destroyed.", status: :see_other }
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
      params.expect(blog_comment: [ :post_id, :body, :author, :liked_by_author ])
    end
end
