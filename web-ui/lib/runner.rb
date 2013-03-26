require 'rack/reverse_proxy'
require "steno"
require "config"
require "bosh_commander"
require "thin"
require 'optparse'
require "../lib/ucc/status_streamer"
require 'yaml'
require 'cgi'


class Rack::Session::Pool
  def initialize app,options={}
    super

    unless $pool != nil
      $pool = Hash.new()
    end

    @pool=$pool
    @mutex=Mutex.new
  end
end

class Rack::AuthenticatedReverseProxy < Rack::ReverseProxy
  def call(env)
    rackreq = Rack::Request.new(env)
    matcher = get_matcher rackreq.fullpath

    unless matcher.nil? || env['rack.session']['user_name']
      return [302, {'Location' => '/login/'}, ['Not authenticated - you are being redirected to the login page.']]
    end

    super
  end
end

module Uhuru::BoshCommander
  class Runner
    def initialize(argv)
      @argv = argv

      # default to production. this may be overriden during opts parsing
      ENV["RACK_ENV"] = "production"
      # default config path. this may be overriden during opts parsing
      @config_file = File.expand_path("../../config/config.yml", __FILE__)
      help_file = File.expand_path("../../config/help.yml", __FILE__)
      forms_file = File.expand_path("../../config/forms.yml", __FILE__)

      parse_options!

      $config = Uhuru::BoshCommander::Config.from_file(@config_file)
      help = File.open(help_file) { |file| YAML.load(file)}

      help.each_key do |key|
        help_items = help[key]

        help[key] = help_items.map do |help_item|
          [help_item['help_item'], help_item['content']]
        end
      end
      $config[:help] = help

      $config[:forms] = File.open(forms_file) { |file| YAML.load(file)}
      $config[:blank_cf_template] = File.expand_path('../../config/blank_cf.yml.erb', __FILE__)
      $config[:infrastructure_yml] = File.expand_path('../../config/infrastructure.yml', __FILE__)
      $config[:deployments_dir] = File.expand_path('../../cf_deployments/', __FILE__)
      $config[:bind_address] = VCAP.local_ip($config[:local_route])
      $config[:director_yml] = File.join($config[:bosh][:base_dir], 'jobs','director','config','director.yml.erb')
      $config[:form_row_template] =

      create_pidfile
      setup_logging
      $config[:logger] = logger
    end

    def logger
      $logger ||= @logger ||= Steno.logger("uhuru-cloud-commander.runner")
    end

    def options_parser
      @parser ||= OptionParser.new do |opts|
        opts.on("-c", "--config [ARG]", "Configuration File") do |opt|
          @config_file = opt
        end

        opts.on("-d", "--development-mode", "Run in development mode") do
          # this must happen before requring any modules that use sinatra,
          # otherwise it will not setup the environment correctly
          @development = true
          ENV["RACK_ENV"] = "development"
        end
      end
    end

    def parse_options!
      options_parser.parse! @argv
    rescue
      puts options_parser
      exit 1
    end

    def create_pidfile
      begin
        pid_file = VCAP::PidFile.new($config[:pid_filename])
        pid_file.unlink_at_exit
      rescue => e
        puts "ERROR: Can't create pid file #{$config[:pid_filename]}"
        exit 1
      end
    end

    def setup_logging
      steno_config = Steno::Config.to_config_hash($config[:logging])
      steno_config[:context] = Steno::Context::ThreadLocal.new
      Steno.init(Steno::Config.new(steno_config))
    end

    def run!
      config = $config.dup

      app = Rack::Builder.new do
        # TODO: we really should put these bootstrapping into a place other
        # than Rack::Builder

        use Rack::CommonLogger
        use Rack::Session::Pool

        use Rack::AuthenticatedReverseProxy do
          # Set :preserve_host to true globally (default is true already)
          reverse_proxy_options :preserve_host => true

          # Forward the path /test* to http://example.com/test*

          tty_js_location = "http://#{$config[:ttyjs][:host]}:#{$config[:ttyjs][:port]}"
          nagios_location = "http://#{$config[:nagios][:host]}:#{$config[:nagios][:port]}"

          reverse_proxy "/user.js", "#{tty_js_location}/user.js"
          reverse_proxy "/user.css", "#{tty_js_location}/user.css"
          reverse_proxy "/style.css", "#{tty_js_location}/style.css"
          reverse_proxy "/tty.js", "#{tty_js_location}/tty.js"
          reverse_proxy "/term.js", "#{tty_js_location}/term.js"
          reverse_proxy "/options.js", "#{tty_js_location}/options.js"
          reverse_proxy '/socket.io', "#{tty_js_location}/"
          reverse_proxy /^\/ssh(\/.*)$/, "#{tty_js_location}/$1"

          reverse_proxy '/nagios/', "#{nagios_location}/"
          reverse_proxy '/pnp4nagios/', "#{nagios_location}"
        end

        map "/nagios" do
          run Proc.new {|env| [302, {'Location' => '/nagios/'}, ['You are being redirected.']]}
        end

        map "/" do
          run Uhuru::BoshCommander::BoshCommander
        end
      end
      @thin_server = Thin::Server.new('0.0.0.0', $config[:port])
      @thin_server.app = app

      trap_signals

      @thin_server.threaded = true
      @thin_server.start!
    end

    def trap_signals
      ["TERM", "INT"].each do |signal|
        trap(signal) do
          @thin_server.stop! if @thin_server
          EM.stop
        end
      end
    end
  end
end
