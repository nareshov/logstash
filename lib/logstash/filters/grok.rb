require "logstash/filters/base"
require "logstash/namespace"

gem "jls-grok", ">=0.4.3"
require "grok" # rubygem 'jls-grok'

class LogStash::Filters::Grok < LogStash::Filters::Base

  config_name "grok"
  config :pattern
  config :patterns_dir
  config :drop_if_match, :validate => :boolean  # googlecode/issue/26

  class << self
    attr_reader :patterns_dir
  end

  flag("--patterns-path PATH", "Colon-delimited path of patterns to load") do |val|
    @patterns_dir ||= ["#{File.dirname(__FILE__)}/../../../patterns/*"]
    @patterns_dir += val.split(":")
  end

  @@grokpiles = Hash.new { |h, k| h[k] = [] }
  @@grokpiles_lock = Mutex.new

  public
  def initialize(params)
    super
  end # def initialize

  public
  def register
    @pile = Grok::Pile.new
    self.class.patterns_dir.each do |path|
      if File.directory?(path)
        path = File.join(path, "*")
      end

      Dir.glob(path).each do |file|
        @logger.info("Grok loading patterns from #{file}")
        @pile.add_patterns_from_file(file)
      end
    end

    @pattern.each do |pattern|
      groks = @pile.compile(pattern)
      @logger.debug(["Compiled pattern", pattern, groks[-1].expanded_pattern])
    end

    @@grokpiles_lock.synchronize do
      @@grokpiles[@type] << @pile
    end
  end # def register

  public
  def filter(event)
    # parse it with grok
    message = event.message
    match = false

    @logger.debug(["Running grok filter", event])
    @@grokpiles[event.type].each do |pile|
      grok, match = @pile.match(message)
      break if match
    end

    if match
      match.each_capture do |key, value|
        match_type = nil
        if key.include?(":")
          name, key, match_type = key.split(":")
        end

        # http://code.google.com/p/logstash/issues/detail?id=45
        # Permit typing of captures by giving an additional colon and a type,
        # like: %{FOO:name:int} for int coercion.
        case match_type
          when "int"
            value = value.to_i
          when "float"
            value = value.to_f
        end

        if event.message == value
          # Skip patterns that match the entire line
          @logger.debug("Skipping capture '#{key}' since it matches the whole line.")
          next
        end

        if event.fields[key].is_a?(String)
          event.fields[key] = [event.fields[key]]
        elsif event.fields[key] == nil
          event.fields[key] = []
        end

        # If value is not nil, or responds to empty and is not empty, add the
        # value to the event.
        if !value.nil? && (!value.empty? rescue true)
          event.fields[key] << value
        end
      end
      filter_matched(event)
    else
      # Tag this event if we can't parse it. We can use this later to
      # reparse+reindex logs if we improve the patterns given .
      event.tags << "_grokparsefailure"
    end

    @logger.debug(["Event now: ", event.to_hash])
  end # def filter
end # class LogStash::Filters::Grok
