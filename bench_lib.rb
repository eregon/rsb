require "json"
require "bundler"

module BenchLib

  # Checked system - error if the command fails
  def csystem(cmd, err, debug: true, fail_ok: false, console: true)
    print "Running command: #{cmd.inspect}\n" if debug
    if console
      system(cmd, out: $stdout, err: $stderr)
    else
      out = `#{cmd}`
    end
    unless $?.success? || fail_ok
      puts "Error running command:\n#{cmd.inspect}"
      puts "Output:\n#{out}\n=====" unless console
      raise err
    end
  end

  # system_environment returns the unlikely-to-change portions of the process's environment
  # in order to tag the data file.
  def system_environment
    {
        "RUBY_VERSION" => RUBY_VERSION,
        "RUBY_DESCRIPTION" => RUBY_DESCRIPTION,
        "rvm current" => `rvm current 2>&1`.strip,
        "repo git sha" => `cd #{__dir__} && git rev-parse HEAD`.chomp,
        "repo status" => `cd #{__dir__} && git status`,
        #"ec2 instance id" => `wget -q -O - http://169.254.169.254/latest/meta-data/instance-id`,
        #"ec2 instance type" => `wget -q -O - http://169.254.169.254/latest/meta-data/instance-type`,
        "uname" => `uname -a`,
        "dir" => Dir.pwd,
    }
  end

  # ServerEnvironment starts and manages a Rails server to benchmark against.
  class ServerEnvironment
    def initialize(server_start_cmd = "rackup", server_pre_cmd: "echo Skipping", server_kill_substring: "rackup", server_kill_command: nil, self_name: "ab_bench", url: "http://localhost:3000")
      @server_start_cmd = server_start_cmd
      @server_pre_cmd = server_pre_cmd
      @server_kill_substring = server_kill_substring
      @server_kill_command = server_kill_command
      @self_name = self_name
      if @server_kill_substring && @server_kill_command
        raise "Can't supply both server kill command and server kill substring!"
      end
      @url = url
    end

    # Note: this only makes sense if we received @server_kill_substring, not @server_kill_command
    def running_server_pids
      ps_out = `ps x`
      proc_lines = ps_out.split("\n").select { |line| line[@server_kill_substring] && !line["grep"] && !line[@self_name] }
      proc_lines.map { |line| line.split(" ", 2)[0].to_i }
    end

    def server_cleanup
      if @server_kill_command
        return csystem(@server_kill_command, "Failure when running server kill command!", fail_ok: true)
      end
      pids = running_server_pids
      return if pids == []
      pids.each { |pid| Process.kill "HUP", pid }
      sleep 3 # Leave time to clean up after SIGHUP
      pids = running_server_pids
      pids.each { |pid| Process.kill "KILL", pid }
    end

    def server_pre_cmd
      csystem("#{@server_pre_cmd}", "Couldn't run precommand(s) (#{@server_pre_cmd.inspect}) for server process!")
    end

    def start_server
      csystem("#{@server_start_cmd} &", "Can't run server!")
    end

    def url_available?
      system("curl #{@url}")
    end

    def ensure_url_available
      100.times do
        return true if url_available?
        sleep 0.3
      end
    end

    def with_url_available
      server_pre_cmd
      start_server
      begin
        ensure_url_available
        yield
      ensure
        server_cleanup
      end
    end
  end

  # A BenchEnvironment is meant to replace a "runner" script - it sets up the environment variables
  # and other system-level configuration for a ServerEnvironment to happen inside.
  #
  # WrkBenchRunner assumes that it will need to fork a separate subprocess to make all of this
  # happen - you can't easily set up a new Ruby/Bundler environment inside your same process
  # without serious side effects.
  #
  # Since a ServerEnvironment requires setting up a lot of configuration, a BenchEnvironment
  # subsumes it - it takes the configuration variables and runs the ServerEnvironment for you rather than having you juggle
  # it manually in between.
  #
  # The blessed method for running the benchmark is #run_wrk. See a runner script ending in .rb
  # for examples of how to use it.
  class BenchmarkEnvironment
    SETTINGS_DEFAULTS = {
      # Wrk settings
      wrk_binary: "wrk",
      wrk_concurrency: 1,            # This is wrk's own "concurrency" setting for number of requests in flight
      wrk_connections: 100,          # Number of connections for wrk to create and use
      warmup_seconds: 5,
      benchmark_seconds: 180,
      wrk_script_location: "./final_report.lua",  # This is the lua script for generating the final report, relative to this source file

      # Ruby config - this interface is clunky and may change
      rvm_ruby_version: nil,
      ruby_change_cmd: "bash -l -c \"rvm use RVM_RUBY_VERSION && ruby wrk_runner.rb JSON_FILENAME\"",
      json_filename: "/tmp/benchlib_#{Process.pid}.json",

      # Bundler/Rack/Gem/Env config
      rack_env: "production", # Sets both $RACK_ENV and $RAILS_ENV
      bundle_gemfile: nil,    # If supplied, set BUNDLE_GEMFILE to value.
      bundler_version: nil,   # If supplied, set BUNDLER_VERSION to value.

      # Benchmarking options
      port: 4321,
      timestamp: Time.now.to_i,
      url: "http://127.0.0.1:PORT/simple_bench/static",
      out_file: "rsb_output_TIME.json",
      verbose: 1,

      # Server environment options
      server_cmd: nil,      # This command should start the server
      server_pre_cmd: nil,  # This command is run at least once before starting the server
      server_kill_command: nil,  # This is a command which, if run, should kill the server
      server_kill_matcher: nil,  # This is a string which, if matched, means "kill this process when killing server"
    }

    def initialize(settings = {})
      settings = settings.dup # Don't modify passed-in original, if any

      # Unset keys get assigned the default
      SETTINGS_DEFAULTS.each do |key, val|
        settings[key] = val unless settings.has_key?(key)
      end

      illegal_keys = settings.keys - SETTINGS_DEFAULTS.keys
      raise "Illegal keys in settings: #{illegal_keys.inspect}!" unless illegal_keys.empty?
      @settings = settings

      # Verify that wrk is installed and available
      if @settings[:wrk_binary] == "wrk"
        which_wrk = `which wrk`
        unless which_wrk && which_wrk.strip != ""
          raise "No wrk binary in path! Build or install the binary and/or specify a path!"
        end
      end

      # Perform text substitution on options
      # In some options, there's a text substitution for variables like PORT and TIMESTAMP
      [:url, :server_cmd, :server_pre_cmd, :server_kill_matcher, :server_kill_command,
        :out_file, :ruby_change_cmd].each do |opt|
        next if @settings[opt].nil?
        @settings[opt] = @settings[opt].gsub "PORT", @settings[:port].to_s # Dup string on first gsub
        @settings[opt].gsub! "TIMESTAMP", @settings[:timestamp].to_s
        @settings[opt].gsub! "RVM_RUBY_VERSION", @settings[:rvm_ruby_version] if @settings[:rvm_ruby_version]
        @settings[opt].gsub! "JSON_FILENAME", @settings[:json_filename]
      end
    end

    # This starts a run of wrk by packaging up settings, setting up configuration,
    # forking a wrk_runner child process and passing everything through.
    #
    # Results will be in @settings[:out_file] once the child process has completed
    # successfully (if it does.)
    def run_wrk
      filename = @settings[:json_filename]
      File.open(filename, "w") { |f| f.write JSON.dump(@settings) }
      exec_with_config @settings[:ruby_change_cmd]
      File.unlink(filename)
    end

    def exec_with_config(cmd_line)
      child_pid = fork do
        Bundler.with_clean_env do
          ENV["RACK_ENV"] = @settings[:rack_env]
          ENV["RAILS_ENV"] = @settings[:rack_env]
          if @settings[:bundle_gemfile]
            ENV["BUNDLE_GEMFILE"] = @settings[:bundle_gemfile]
          end
          if @settings[:bundler_version]
            ENV["BUNDLER_VERSION"] = @settings[:bundler_version]
          end
          STDERR.puts "exec: #{cmd_line.inspect}"
          exec cmd_line
        end
      end
      # Now wait for the benchmark to finish
      Process.wait(child_pid)
    end

    def verbose(s)
      if @settings[:verbose]
        puts s
      end
    end

    def capture_environment
      env_vars = ENV.keys
      important_env_vars = ["LD_PRELOAD"] + env_vars.select { |name| name.downcase["ruby"] || name.downcase["gem"] || name.downcase["rsb"] }
      env_hash = {}
      important_env_vars.each { |var| env_hash["env-#{var}"] = ENV[var] }
      env_hash["wrk_path"] = `which wrk`

      # Information about the host we're running on
      {
          "version" => "wrk:2", # version of output format
          "settings" => @settings,  # command-line and environmental settings for this script
          "environment" => BenchLib.system_environment.merge(env_hash),
          "requests" => {
            "warmup" => {},
            "benchmark" => {},
            #"benchmark_min_starttime"
            #"benchmark_max_starttime"
          }
      }
    end

    def parse_wrk_into_stats(str)
      out = {}

      # The output is human-readable text, followed by the output of final_report.lua
      first, second = str.split("-- Final Report")

      if second =~ /^Latencies: \[(.*)\]$/
        out[:latencies] = $1.split(",")[0..-2].map(&:to_i) # There's a final comma that shows up as a blank
      else
        raise "Could not locate latency data!"
      end
      out[:latencies].pop if out[:latencies][-1] == 0

      if second =~ /^Per-Thread ReqsPerSec: \[(.*)\]$/
        out[:req_per_sec] = $1.split(",")[0..-2].map(&:to_i)# There's a final comma that shows up as a blank
      else
        raise "Could not locate requests/sec data!"
      end

      if second =~ /^Summary Errors: connect:([0-9]+),read:([0-9]+),write:([0-9]+),status:([0-9]+),timeout:([0-9]+)$/
        out[:errors] = {
          connect: $1.to_i,
          read: $2.to_i,
          write: $3.to_i,
          status: $4.to_i,
          timeout: $5.to_i,
        }
      else
        raise "Could not locate error data!"
      end
      out
    end

    # This is run by the child process's wrk_runner.rb as a top-level method
    def run_wrk_bench
      output = capture_environment

      server_env = ServerEnvironment.new @settings[:server_cmd],
                                         server_pre_cmd: @settings[:server_pre_cmd],
                                         server_kill_substring: @settings[:server_kill_matcher],
                                         server_kill_command: @settings[:server_kill_command],
                                         self_name: "wrk_bench",
                                         url: @settings[:url]

      # If we know how to make sure the server isn't running, do that.
      if @settings[:server_kill_matcher]
        server_env.server_cleanup
      end

      raise "URL #{@settings[:url].inspect} should not be available before the server runs!" if server_env.url_available?

      server_env.with_url_available do
        verbose "Starting warmup iterations"
        # Warmup iterations first
        wrk_script_location = File.join(__dir__, @settings[:wrk_script_location])
        csystem("#{@settings[:wrk_binary]} -t#{@settings[:wrk_concurrency]} -c#{@settings[:wrk_connections]} -d#{@settings[:warmup_seconds]}s -s#{wrk_script_location} --latency #{@settings[:url]} > warmup_output_#{@settings[:timestamp]}.txt", "Couldn't run warmup iterations!")

        verbose "Starting real benchmark iterations"
        csystem("#{@settings[:wrk_binary]} -t#{@settings[:wrk_concurrency]} -c#{@settings[:wrk_connections]} -d#{@settings[:benchmark_seconds]}s -s#{wrk_script_location} --latency #{@settings[:url]} > benchmark_output_#{@settings[:timestamp]}.txt", "Couldn't run warmup iterations!")
      end

      raise "URL #{@settings[:url].inspect} should not be available after the kill command (#{@settings[:server_kill_matcher].inspect})!" if server_env.url_available?

      # Read wrk's output, parse into our own output array
      output["requests"]["warmup"] = parse_wrk_into_stats(File.read "warmup_output_#{@settings[:timestamp]}.txt")
      output["requests"]["benchmark"] = parse_wrk_into_stats(File.read "benchmark_output_#{@settings[:timestamp]}.txt")

      File.unlink "warmup_output_#{@settings[:timestamp]}.txt"
      File.unlink "benchmark_output_#{@settings[:timestamp]}.txt"

      json_text = JSON.pretty_generate(output)
      File.open(@settings[:out_file], "w") do |f|
        f.write json_text
      end

      verbose "All data files written successfully."
    end


  end

  module ApacheBenchClient
    def self.installed?
      which_ab = `which ab`
      which_ab && which_ab.strip != ""
    end
  end

end
