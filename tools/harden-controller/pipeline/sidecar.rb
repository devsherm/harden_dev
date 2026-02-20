# frozen_string_literal: true

class Pipeline
  module Sidecar
    private

    def sidecar_path(controller_path, filename)
      File.join(File.dirname(controller_path), ".harden", File.basename(controller_path, ".rb"), filename)
    end

    def ensure_harden_dir(controller_path)
      dir = File.join(File.dirname(controller_path), ".harden", File.basename(controller_path, ".rb"))
      FileUtils.mkdir_p(dir)
    end

    def write_sidecar(controller_path, filename, content)
      path = sidecar_path(controller_path, filename)
      real = File.realpath(File.dirname(path))
      allowed = "#{File.realpath(File.join(@rails_root, "app", "controllers"))}/"
      raise "Sidecar path #{path} escapes controllers directory" unless real.start_with?(allowed)
      File.write(path, content.end_with?("\n") ? content : "#{content}\n")
    end

    def safe_write(path, content)
      real = File.realpath(File.dirname(path))
      allowed = "#{File.realpath(File.join(@rails_root, "app", "controllers"))}/"
      raise "Path #{path} escapes controllers directory" unless real.start_with?(allowed)
      File.write(path, content)
    end

    def derive_test_path(controller_path)
      # app/controllers/blog/posts_controller.rb → test/controllers/blog/posts_controller_test.rb
      relative = controller_path.sub("#{@rails_root}/", "")
      test_relative = relative
        .sub(%r{\Aapp/controllers/}, "test/controllers/")
        .sub(/\.rb\z/, "_test.rb")
      path = File.join(@rails_root, test_relative)
      File.exist?(path) ? path : nil
    end
  end
end
