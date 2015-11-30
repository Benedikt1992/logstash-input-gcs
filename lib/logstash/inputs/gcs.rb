# encoding: utf-8
require 'gcloud'

require 'faraday'
module Faraday
  class Adapter
    class NetHttp < Faraday::Adapter
      def ssl_verify_mode(ssl)
        OpenSSL::SSL::VERIFY_NONE
      end
    end
  end
end

require "logstash/inputs/base"
require "logstash/namespace"
require "time"
require "tmpdir"
require "stud/interval"
require "stud/temporary"

# Stream events from files from a S3 bucket.
#
# Each line from each file generates an event.
# Files ending in `.gz` are handled as gzip'ed files.
class LogStash::Inputs::GCS < LogStash::Inputs::Base
  config_name "gcs"

  default :codec, "plain"

  config :project

  # Path to JSON file containing the Service Account credentials (not needed when running inside GCE)
  config :keyfile

  # The name of the GCS bucket.
  config :bucket, :validate => :string, :required => true

  # If specified, the prefix of filenames in the bucket must match (not a regexp)
  config :prefix, :validate => :string, :default => nil

  # Where to write the since database (keeps track of the date
  # the last handled file was added to S3). The default will write
  # sincedb files to some path matching "$HOME/.sincedb*"
  # Should be a path with filename not just a directory.
  config :sincedb_path, :validate => :string, :default => nil

  # Name of a S3 bucket to backup processed files to.
  config :backup_to_bucket, :validate => :string, :default => nil

  # Append a prefix to the key (full path including file name in s3) after processing.
  # If backing up to another (or the same) bucket, this effectively lets you
  # choose a new 'folder' to place the files in
  config :backup_add_prefix, :validate => :string, :default => nil

  # Path of a local directory to backup processed files to.
  config :backup_to_dir, :validate => :string, :default => nil

  # Whether to delete processed files from the original bucket.
  config :delete, :validate => :boolean, :default => false

  # Interval to wait between to check the file list again after a run is finished.
  # Value is in seconds.
  config :interval, :validate => :number, :default => 60

  # Ruby style regexp of keys to exclude from the bucket
  config :exclude_pattern, :validate => :string, :default => nil

  # Set the directory where logstash will store the tmp files before processing them.
  # default to the current OS temporary directory in linux /tmp/logstash
  config :temporary_directory, :validate => :string, :default => File.join(Dir.tmpdir, "logstash")

  public
  def register
    require "fileutils"
    require "digest/md5"

    @logger.info("Registering GCS input", :bucket => @bucket, :project => @project, :keyfile => @keyfile)

    @gcs = Gcloud.new(project=@project, keyfile=@keyfile).storage 
    @gcsbucket = @gcs.bucket @bucket

    unless @backup_to_bucket.nil?
      @backup_bucket = @gcs.bucket @backup_to_bucket
      unless @backup_bucket
        @gcs.create_bucket(@backup_to_bucket)
      end
    end

    unless @backup_to_dir.nil?
      Dir.mkdir(@backup_to_dir, 0700) unless File.exists?(@backup_to_dir)
    end

    FileUtils.mkdir_p(@temporary_directory) unless Dir.exist?(@temporary_directory)
  end # def register

  public
  def run(queue)
    @current_thread = Thread.current
    Stud.interval(@interval, sleep_then_run: false) do
      process_files(queue)
    end
  end # def run

  public
  def list_new_files
    @logger.debug("GCS input: Polling")

    objects = {}
    @gcsbucket.files({prefix: @prefix}).each do |file|
      @logger.debug("GCS input: Found file", :name => file.name)

      unless ignore_filename?(file.name)
        if sincedb.newer?(file.updated_at())
          objects[file.name] = file.updated_at()
          @logger.debug("GCS input: Adding to objects[]", :name => file.name)
        end
      end
    end
    return objects.keys.sort {|a,b| objects[a] <=> objects[b]}
  end # def fetch_new_files

  public
  def backup_to_bucket(object, key)
    # TODO (barak)
    unless @backup_to_bucket.nil?
      backup_key = "#{@backup_add_prefix}#{key}"
      if @delete
        object.move_to(backup_key, :bucket => @backup_bucket)
      else
        object.copy_to(backup_key, :bucket => @backup_bucket)
      end
    end
  end

  public
  def backup_to_dir(filename)
    unless @backup_to_dir.nil?
      FileUtils.cp(filename, @backup_to_dir)
    end
  end

  public
  def process_files(queue)
    objects = list_new_files

    objects.each do |file|
      if stop?
        break
      else
        @logger.debug("GCS input processing", :bucket => @bucket, :file => file)
        process_log(queue, file)
      end
    end
  end # def process_files

  public
  def stop
    # @current_thread is initialized in the `#run` method,
    # this variable is needed because the `#stop` is a called in another thread
    # than the `#run` method and requiring us to call stop! with a explicit thread.
    Stud.stop!(@current_thread)
  end

  private

  # Read the content of the local file
  #
  # @param [Queue] Where to push the event
  # @param [String] Which file to read from
  # @return [Boolean] True if the file was completely read, false otherwise.
  def process_local_log(queue, filename)
    @logger.debug('Processing file', :filename => filename)

    metadata = {}
    # Currently codecs operates on bytes instead of stream.
    # So all IO stuff: decompression, reading need to be done in the actual
    # input and send as bytes to the codecs.
    read_file(filename) do |line|
      if stop?
        @logger.warn("Logstash GCS input, stop reading in the middle of the file, we will read it again when logstash is started")
        return false
      end

      @codec.decode(line) do |event|
        decorate(event)
        queue << event
      end
    end

    return true
  end # def process_local_log

  private
  def read_file(filename, &block)
    if gzip?(filename)
      read_gzip_file(filename, block)
    else
      read_plain_file(filename, block)
    end
  end

  def read_plain_file(filename, block)
    File.open(filename, 'rb') do |file|
      file.each(&block)
    end
  end

  private
  def read_gzip_file(filename, block)
    begin
      Zlib::GzipReader.open(filename) do |decoder|
        decoder.each_line { |line| block.call(line) }
      end
    rescue Zlib::Error, Zlib::GzipFile::Error => e
      @logger.error("Gzip codec: We cannot uncompress the gzip file", :filename => filename)
      raise e
    end
  end

  private
  def gzip?(filename)
    filename.end_with?('.gz')
  end

  private
  def sincedb
    @sincedb ||= if @sincedb_path.nil?
                   @logger.info("Using default generated file for the sincedb", :filename => sincedb_file)
                   SinceDB::File.new(sincedb_file)
                 else
                   @logger.info("Using the provided sincedb_path",
                                :sincedb_path => @sincedb_path)
                   SinceDB::File.new(@sincedb_path)
                 end
  end

  private
  def sincedb_file
    File.join(ENV["HOME"], ".sincedb_" + Digest::MD5.hexdigest("#{@bucket}+#{@prefix}"))
  end

  private
  def ignore_filename?(filename)
    if @prefix == filename
      return true
    elsif (@backup_add_prefix && @backup_to_bucket == @bucket && filename =~ /^#{backup_add_prefix}/)
      return true
    elsif @exclude_pattern.nil?
      return false
    elsif filename =~ Regexp.new(@exclude_pattern)
      return true
    else
      return false
    end
  end

  private
  def process_log(queue, key)
    object = @gcsbucket.file key

    filename = File.join(temporary_directory, File.basename(key))

    @logger.debug("GCS input: Download remote file", :remote_key => object.name, :local_filename => filename)
    object.download filename

    if process_local_log(queue, filename)
        backup_to_bucket(object, key)
        backup_to_dir(filename)
        delete_file_from_bucket(object)
        FileUtils.remove_entry_secure(filename, true)
        lastmod = object.updated_at()
        sincedb.write(lastmod)
    else
      FileUtils.remove_entry_secure(filename, true)
    end
  end

  private
  def delete_file_from_bucket(object)
    if @delete and @backup_to_bucket.nil?
      object.delete()
    end
  end


  private
  module SinceDB
    class File
      def initialize(file)
        @sincedb_path = file
      end

      def newer?(date)
        date > read
      end

      def read
        if ::File.exists?(@sincedb_path)
          content = ::File.read(@sincedb_path).chomp.strip
          # If the file was created but we didn't have the time to write to it
          return content.empty? ? Time.new(0) : Time.parse(content)
        else
          return Time.new(0)
        end
      end

      def write(since = nil)
        since = Time.now() if since.nil?
        ::File.open(@sincedb_path, 'w') { |file| file.write(since.to_s) }
      end
    end
  end
end # class LogStash::Inputs::GCS
