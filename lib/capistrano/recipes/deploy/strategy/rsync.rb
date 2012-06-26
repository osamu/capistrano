require 'capistrano/recipes/deploy/strategy/base'
require 'fileutils'
require 'tempfile'  # Dir.tmpdir

module Capistrano
  module Deploy
    module Strategy
      #   set :checkout_strategy, :export
      #   set :rsync_exclude, ".git/*"
      #   set :build_script, "make all"

      class Rsync < Base

        def deploy!
          run_checkout_strategy
          create_revision_file
          upload_to_rsync_servers
          distribute!
        ensure
          rollback_changes
        end

        def build directory
          execute "running build script on #{directory}" do
            Dir.chdir(directory) { system(build_script) }
          end if build_script
        end

        def check!
          super.check do |d|
            d.local.command(source.local.command) if source.local.command
            d.local.command(compress(nil, nil).first)
            d.remote.command(decompress(nil).first)
          end
        end

        private

          def run_checkout_strategy
            copy_repository_to_server
            build destination
            remove_excluded_files if rsync_exclude.any?
          end

          def execute description, &block
            logger.debug description
            handle_system_errors &block
          end

          def handle_system_errors &block
            block.call
            raise_command_failed if last_command_failed?
          end

          def raise_command_failed
            raise Capistrano::Error, "shell command failed with return code #{$?}"
          end

          def last_command_failed?
            $? != 0
          end

          def copy_cache_to_staging_area
            execute "copying cache to deployment staging area #{destination}" do
              create_destination
              Dir.chdir(copy_cache) { copy_files(queue_files) }
            end
          end

          def create_destination
            FileUtils.mkdir_p(destination)
          end

          def copy_files files
            files.each { |name| process_file(name) }
          end

          def process_file name
            send "copy_#{filetype(name)}", name
          end

          def filetype name
            filetype = File.ftype name
            filetype = "file" unless ["link", "directory"].include? filetype
            filetype
          end

          def copy_link name
            FileUtils.ln_s(File.readlink(name), File.join(destination, name))
          end

          def copy_directory name
            FileUtils.mkdir(File.join(destination, name))
            copy_files(queue_files(name))
          end

          def copy_file name
            FileUtils.ln(name, File.join(destination, name))
          end

          def queue_files directory=nil
            Dir.glob(pattern_for(directory), File::FNM_DOTMATCH).reject! { |file| excluded_files_contain? file }
          end

          def pattern_for directory
            !directory.nil? ? "#{directory}/*" : "*"
          end

          def excluded_files_contain? file
            rsync_exclude.any? { |p| File.fnmatch(p, file) } or [ ".", ".."].include? File.basename(file)
          end

          def copy_repository_to_server
            execute "getting (via #{checkout_strategy}) revision #{revision} to #{destination}" do
              copy_repository_via_strategy
            end
          end

          def copy_repository_via_strategy
              system(command)
          end

          def remove_excluded_files
            logger.debug "processing exclusions..."

            rsync_exclude.each do |pattern|
              delete_list = Dir.glob(File.join(destination, pattern), File::FNM_DOTMATCH)
              # avoid the /.. trap that deletes the parent directories
              delete_list.delete_if { |dir| dir =~ /\/\.\.$/ }
              FileUtils.rm_rf(delete_list.compact)
            end
          end

          def create_revision_file
            File.open(File.join(destination, "REVISION"), "w") { |f| f.puts(revision) }
          end

          def rollback_changes
            FileUtils.rm filename rescue nil
            FileUtils.rm_rf destination rescue nil
          end

          def build_script
            configuration[:build_script]
          end

          def rsync_exclude
            @rsync_exclude ||= Array(configuration.fetch(:rsync_exclude, []))
          end

          def destination
            @destination ||= File.join(copy_dir, File.basename(configuration[:release_path]))
          end

          def checkout_strategy
            @checkout_strategy ||= configuration.fetch(:checkout_strategy, :checkout)
          end

          # Should return the command(s) necessary to obtain the source code
          # locally.
          def command
            @command ||= case checkout_strategy
            when :checkout
              source.checkout(revision, destination)
            when :export
              source.export(revision, destination)
            end
          end

          # Returns the name of the file that the source code will be
          # compressed to.
          def filename
            @filename ||= File.join(copy_dir, "#{File.basename(destination)}.#{compression.extension}")
          end

          # The directory to which the copy should be checked out
          def copy_dir
            @copy_dir ||= File.expand_path(configuration[:copy_dir] || Dir.tmpdir, Dir.pwd)
          end

          # The directory on the remote server to which the archive should be
          # copied
          def remote_dir
            @remote_dir ||= configuration[:copy_remote_dir] || "/tmp"
          end

          # The location on the remote server where the file should be
          # temporarily stored.
          def remote_filename
            @remote_filename ||= File.join(remote_dir, File.basename(filename))
          end
          
          def rsync_server
            @rsync_server ||= configuration[:rsync_server] || "localhost:/tmp/base"
          end
          
          def upload_to_rsync_servers
            
            upload(filename, remote_filename)
            decompress_remote_file
          end

          # A struct for representing the specifics of a compression type.
          # Commands are arrays, where the first element is the utility to be
          # used to perform the compression or decompression.
          Compression = Struct.new(:extension, :compress_command, :decompress_command)

          # The compression method to use, defaults to :gzip.
          def compression
            remote_tar = configuration[:copy_remote_tar] || 'tar'
            local_tar = configuration[:copy_local_tar] || 'tar'

            type = configuration[:copy_compression] || :gzip
            case type
            when :gzip, :gz   then Compression.new("tar.gz",  [local_tar, 'czf'], [remote_tar, 'xzf'])
            when :bzip2, :bz2 then Compression.new("tar.bz2", [local_tar, 'cjf'], [remote_tar, 'xjf'])
            when :zip         then Compression.new("zip",     %w(zip -qyr), %w(unzip -q))
            else raise ArgumentError, "invalid compression type #{type.inspect}"
            end
          end

          # Returns the command necessary to compress the given directory
          # into the given file.
          def compress(directory, file)
            compression.compress_command + [file, directory]
          end

          # Returns the command necessary to decompress the given file,
          # relative to the current working directory. It must also
          # preserve the directory structure in the file.
          def decompress(file)
            compression.decompress_command + [file]
          end

          def decompress_remote_file
            run "cd #{configuration[:releases_path]} && #{decompress(remote_filename).join(" ")} && rm #{remote_filename}"
          end
          

          def select_rsync_server
            rand
          end

          
          # Distributes the file to the remote servers
          def distribute!
            run_rsync("echo rsync -qa #{select_rsync_server} to release_path")
          end

          def run_rsync(command)
            run(command) do |ch,stream,text|
              ch[:state] ||= { :channel => ch }
              output = source.handle_data(ch[:state], stream, text)
              ch.send_data(output) if output
            end
          end

      end

    end
  end
end
