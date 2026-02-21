# frozen_string_literal: true

require_relative "lock_manager"

class Pipeline
  module Sidecar
    private

    def sidecar_path(target_path, filename)
      File.join(File.dirname(target_path), @sidecar_dir, File.basename(target_path, ".rb"), filename)
    end

    def ensure_sidecar_dir(target_path)
      dir = File.join(File.dirname(target_path), @sidecar_dir, File.basename(target_path, ".rb"))
      FileUtils.mkdir_p(dir)
    end

    def write_enhance_sidecar(target_path, filename, content)
      path = enhance_sidecar_path(target_path, filename)
      FileUtils.mkdir_p(File.dirname(path))
      real = File.realpath(File.dirname(path))
      unless @enhance_allowed_write_paths.any? { |p| real.start_with?("#{File.realpath(File.join(@rails_root, p))}/") }
        raise "Enhance sidecar path #{path} escapes allowed directories"
      end
      File.write(path, content)
    end

    def write_sidecar(target_path, filename, content)
      path = sidecar_path(target_path, filename)
      real = File.realpath(File.dirname(path))
      unless @allowed_write_paths.any? { |p| real.start_with?("#{File.realpath(File.join(@rails_root, p))}/") }
        raise "Sidecar path #{path} escapes allowed directories"
      end
      File.write(path, content.end_with?("\n") ? content : "#{content}\n")
    end

    def safe_write(path, content, grant_id: nil)
      if grant_id
        # Enhance mode: validate against enhance_allowed_write_paths and the lock grant
        allowlist = @enhance_allowed_write_paths
        real = File.realpath(File.dirname(path))
        unless allowlist.any? { |p| real.start_with?("#{File.realpath(File.join(@rails_root, p))}/") }
          raise LockViolationError, "Path #{path} escapes enhance allowed directories"
        end

        grant = @lock_manager&.find_grant(grant_id)
        raise LockViolationError, "Invalid or unknown grant: #{grant_id}" unless grant
        raise LockViolationError, "Grant #{grant_id} has expired or been released" unless grant.active?
        unless grant.write_paths.include?(path)
          raise LockViolationError, "Path #{path} is not covered by grant #{grant_id}"
        end
      else
        # Hardening mode: validate against allowed_write_paths (existing behavior)
        real = File.realpath(File.dirname(path))
        unless @allowed_write_paths.any? { |p| real.start_with?("#{File.realpath(File.join(@rails_root, p))}/") }
          raise "Path #{path} escapes allowed directories"
        end
      end
      File.write(path, content)
    end

    # Construct the staging directory path within the sidecar.
    # Returns: /path/to/.harden/<controller_name>/staging
    def staging_path(target_path)
      File.join(File.dirname(target_path), @sidecar_dir, File.basename(target_path, ".rb"), "staging")
    end

    # Walk the staging directory and copy each file to its real path via safe_write.
    # staging_dir mirrors the app directory structure:
    #   staging/app/controllers/posts_controller.rb → app/controllers/posts_controller.rb
    def copy_from_staging(staging_dir, grant_id: nil)
      Dir.glob(File.join(staging_dir, "**", "*")).each do |staged_file|
        next if File.directory?(staged_file)
        relative = staged_file.sub("#{staging_dir}/", "")
        real_path = File.join(@rails_root, relative)
        FileUtils.mkdir_p(File.dirname(real_path))
        safe_write(real_path, File.read(staged_file), grant_id: grant_id)
      end
    end

    def derive_test_path(target_path)
      @test_path_resolver.call(target_path, @rails_root)
    end

    def default_derive_test_path(controller_path, rails_root)
      # app/controllers/blog/posts_controller.rb → test/controllers/blog/posts_controller_test.rb
      relative = controller_path.sub("#{rails_root}/", "")
      test_relative = relative
        .sub(%r{\Aapp/controllers/}, "test/controllers/")
        .sub(/\.rb\z/, "_test.rb")
      path = File.join(rails_root, test_relative)
      File.exist?(path) ? path : nil
    end
  end
end
