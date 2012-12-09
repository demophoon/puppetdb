require 'puppet/error'
require 'puppet/util/puppetdb/command_names'
require 'puppet/util/puppetdb/char_encoding'

class Puppet::Util::Puppetdb::Command
  include Puppet::Util::Puppetdb::CommandNames

  Url = "/v2/commands"
  SpoolSubDir        = File.join("puppetdb", "commands")

  # Public class methods

  def self.each_enqueued_command
    all_command_files.each do |command_file_path|
      command = load_command(command_file_path)
      yield command
    end
  end

  # Public instance methods

  # Constructor;
  #
  # @param command String the name of the command; should be one of the
  #   constants defined in `Puppet::Util::Puppetdb::CommandNames`
  # @param version Integer the command version number
  # @param payload Object the payload of the command.  This object should be a
  #   primitive (numeric type, string, array, or hash) that is natively supported
  #   by JSON serialization / deserialization libraries.
  # @param options Hash you should rarely need to use this parameter; it supports
  #   a few low-level operations regarding how the constructor should behave.
  #   - :format_payload: defaults to true; the internal representation of the
  #        payload should always be a JSON string, so by default, the constructor
  #        will format and serialize the payload according to the wire format
  #        specification.  However, in rare cases (such as when you are loading
  #        a command from a file and the payload has already been formatted and
  #        serialized), you may wish to pass `false` here to skip this step.
  def initialize(command, version, certname, payload, options = {})

    default_options = { :format_payload => true }
    options = default_options.merge(options)

    @command = command
    @version = version
    @certname = certname
    @payload = options[:format_payload] ?
                  self.class.format_payload(command, version, payload) :
                  payload
    unless @payload.is_a? String
      raise Puppet::Error, "payload must be a String (perhaps you passed :format_payload => false?)"
    end
  end

  attr_reader :command, :version, :certname, :payload

  def ==(other)
    (@command == other.command) &&
        (@version == other.version) &&
        (@certname == other.certname) &&
        (@payload == other.payload)
  end


  def queued?
    File.exists?(spool_file_path)
  end

  def enqueue
    File.open(spool_file_path, "w") do |f|
      f.puts(command)
      f.puts(version)
      f.puts(certname)
      f.write(payload)
    end
    Puppet.info("Spooled PuppetDB command for node '#{certname}' to file: '#{spool_file_path}'")
  end

  def dequeue
    File.delete(spool_file_path)
  end


  private

  ## Private class methods

  def self.format_payload(command, version, payload)
    message = {
        :command => command,
        :version => version,
        :payload => payload,
    }.to_pson

    Puppet::Util::Puppetdb::CharEncoding.utf8_string(message)
  end

  def self.load_command(command_file_path)
    File.open(command_file_path, "r") do |f|
      command = f.readline.strip
      version = f.readline.strip.to_i
      certname = f.readline.strip
      payload = f.read
      self.new(command, version, certname, payload, :format_payload => false)
    end
  end

  def self.spool_dir
    unless (@spool_dir)
      @spool_dir = File.join(Puppet[:vardir], SpoolSubDir)
      FileUtils.mkdir_p(@spool_dir)
    end
    @spool_dir
  end

  def self.all_command_files
    # this method is mostly useful for testing purposes
    Dir.glob(File.join(spool_dir, "*.command"))
  end

  def self.clear_queue
    # this method is mostly useful for cleaning up after tests
    all_command_files.each do |f|
      File.delete(f)
    end
  end

  ## Private instance methods

  def spool_file_name
    unless (@spool_file_name)
      # TODO: the logic for this method probably needs to be improved.  For the time
      # being, we are giving the catalog/fact commands very specific filenames
      # that are intended to prevent the existence of more than one catalog/fact
      # command per node in the spool dir.  Otherwise we'd need to deal with
      # ordering issues.
      clean_command_name = command.gsub(/[^\w_]/, "_")
      if ([CommandReplaceCatalog, CommandReplaceFacts].include?(command))
        @spool_file_name = "#{certname}_#{clean_command_name}.command"
      else
        # otherwise we're using a sha1 of the payload to try to prevent filename collisions.
        @spool_file_name = "#{certname}_#{clean_command_name}_#{Digest::SHA1.hexdigest(payload.to_pson)}.command"
      end
    end
    @spool_file_name
  end

  def spool_file_path
    File.join(self.class.spool_dir, spool_file_name)
  end

end