# frozen_string_literal: true

module Tmuxinator
  class Project
    include Tmuxinator::Util
    include Tmuxinator::Deprecations
    include Tmuxinator::Hooks::Project

    RBENVRVM_DEP_MSG = <<-M
    DEPRECATION: rbenv/rvm-specific options have been replaced by the
    `pre_tab` option and will not be supported in 0.8.0.
    M
    TABS_DEP_MSG = <<-M
    DEPRECATION: The tabs option has been replaced by the `windows` option
    and will not be supported in 0.8.0.
    M
    CLIARGS_DEP_MSG = <<-M
    DEPRECATION: The `cli_args` option has been replaced by the `tmux_options`
    option and will not be supported in 0.8.0.
    M
    SYNC_DEP_MSG = <<-M
    DEPRECATION: The `synchronize` option's current default behaviour is to
    enable pane synchronization before running commands. In a future release,
    the default synchronization option will be `after`, i.e. synchronization of
    panes will occur after the commands described in each of the panes
    have run. At that time, the current behavior will need to be explicitly
    enabled, using the `synchronize: before` option. To use this behaviour
    now, use the 'synchronize: after' option.
    M
    PRE_DEP_MSG = <<-M
    DEPRECATION: The `pre` option has been replaced by project hooks (`on_project_start` and
    `on_project_restart`) and will be removed in a future release.
    M
    POST_DEP_MSG = <<-M
    DEPRECATION: The `post` option has been replaced by project hooks (`on_project_stop` and
    `on_project_exit`) and will be removed in a future release.
    M

    attr_reader :yaml
    attr_reader :force_attach
    attr_reader :force_detach
    attr_reader :custom_name
    attr_reader :no_pre_window

    class << self
      include Tmuxinator::Util

      def load(path, options = {})
        yaml = begin
          args = options[:args] || []
          @settings = parse_settings(args)
          @args = args

          content = render_template(path, binding)
          YAML.safe_load(content, aliases: true)
               rescue SyntaxError, StandardError => error
                 raise "Failed to parse config file: #{error.message}"
        end

        new(yaml, options)
      end

      def parse_settings(args)
        settings = args.select { |x| x.match(/.*=.*/) }
        args.reject! { |x| x.match(/.*=.*/) }

        settings.map! do |setting|
          parts = setting.split("=", 2)
          [parts[0], parts[1]]
        end

        Hash[settings]
      end

      def active
        Tmuxinator::Config.configs(active: true).
          map { |config| Config.validate(name: config) }
      end

      def stop_all
        active.
          sort_by { |project| project.name == current_session_name ? 1 : 0 }.
          each { |project| Kernel.system(project.kill) }
      end
    end

    def validate!
      raise "Your project file should include some windows." \
        unless windows?
      raise "Your project file didn't specify a 'project_name'" \
        unless name?

      self
    end

    def initialize(yaml, options = {})
      options[:force_attach] = false if options[:force_attach].nil?
      options[:force_detach] = false if options[:force_detach].nil?

      @yaml = yaml

      set_instance_variables_from_options(options)

      validate_options

      extend Tmuxinator::WemuxSupport if wemux?
    end

    def set_instance_variables_from_options(options)
      @custom_name = options[:custom_name]
      @force_attach = options[:force_attach]
      @force_detach = options[:force_detach]
      @append = options[:append]
      @no_pre_window = options[:no_pre_window]
    end

    def validate_options
      if @force_attach && @force_detach
        raise "Cannot force_attach and force_detach at the same time"
      end

      if append? && !tmux_has_session?(name)
        raise "Cannot append to a session that does not exist"
      end
    end

    def render
      self.class.render_template(Tmuxinator::Config.template, binding)
    end

    def kill
      self.class.render_template(Tmuxinator::Config.stop_template, binding)
    end

    def self.render_template(template, bndg)
      content = File.read(template)
      bndg.eval(Erubi::Engine.new(content).src)
    end

    def windows
      windows_yml = yaml["tabs"] || yaml["windows"]

      @windows ||= (windows_yml || {}).map.with_index do |window_yml, index|
        Tmuxinator::Window.new(window_yml, index, self)
      end
    end

    def root
      root = yaml["project_root"] || yaml["root"]
      blank?(root) ? nil : File.expand_path(root).shellescape
    end

    def name
      name =
        if append?
          current_session_name
        else
          custom_name || yaml["project_name"] || yaml["name"]
        end

      blank?(name) ? nil : name.to_s.shellescape
    end

    def append?
      @append
    end

    def pre
      pre_config = yaml["pre"]
      parsed_parameters(pre_config)
    end

    def attach?
      yaml_attach = if yaml["attach"].nil?
                      true
                    else
                      yaml["attach"]
                    end
      attach = force_attach || !force_detach && yaml_attach
      attach
    end

    def pre_window
      return if no_pre_window

      params = if rbenv?
                 "rbenv shell #{yaml['rbenv']}"
               elsif rvm?
                 "rvm use #{yaml['rvm']}"
               elsif pre_tab?
                 yaml["pre_tab"]
               else
                 yaml["pre_window"]
               end
      parsed_parameters(params)
    end

    def post
      post_config = yaml["post"]
      parsed_parameters(post_config)
    end

    def tmux
      "#{tmux_command}#{tmux_options}#{socket}"
    end

    def tmux_command
      yaml["tmux_command"] || "tmux"
    end

    def tmux_has_session?(name)
      return false unless name

      # Redirect stderr to /dev/null in order to prevent "failed to connect
      # to server: Connection refused" error message and non-zero exit status
      # if no tmux sessions exist.
      # Please see issues #402 and #414.
      sessions = `#{tmux} ls 2> /dev/null`

      # Remove any escape sequences added by `shellescape` in Project#name.
      # Escapes can result in: "ArgumentError: invalid multibyte character"
      # when attempting to match `name` against `sessions`.
      # Please see issue #564.
      unescaped_name = name.shellsplit.join("")

      !(sessions !~ /^#{unescaped_name}:/)
    end

    def socket
      if socket_path
        " -S #{socket_path}"
      elsif socket_name
        " -L #{socket_name}"
      end
    end

    def socket_name
      yaml["socket_name"]
    end

    def socket_path
      yaml["socket_path"]
    end

    def tmux_options
      if cli_args?
        " #{yaml['cli_args'].to_s.strip}"
      elsif tmux_options?
        " #{yaml['tmux_options'].to_s.strip}"
      else
        ""
      end
    end

    def last_window_index
      `tmux list-windows -F '#I'`.split.last.to_i
    end

    def base_index
      return last_window_index + 1 if append?

      get_base_index.to_i
    end

    def pane_base_index
      get_pane_base_index.to_i
    end

    def startup_window
      "#{name}:#{yaml['startup_window'] || base_index}"
    end

    def startup_pane
      "#{startup_window}.#{yaml['startup_pane'] || pane_base_index}"
    end

    def tmux_options?
      yaml["tmux_options"]
    end

    def windows?
      windows.any?
    end

    def root?
      !root.nil?
    end

    def name?
      !name.nil?
    end

    def window(index)
      append? ? ":#{index}" : "#{name}:#{index}"
    end

    def send_pane_command(cmd, window_index, _pane_index)
      send_keys(cmd, window_index)
    end

    def send_keys(cmd, window_index)
      if cmd.empty?
        ""
      else
        "#{tmux} send-keys -t #{window(window_index)} #{cmd.shellescape} C-m"
      end
    end

    def deprecations
      deprecation_checks.zip(deprecation_messages).
        inject([]) do |deps, (chk, msg)|
        deps << msg if chk
        deps
      end
    end

    def deprecation_checks
      [
        rvm_or_rbenv?,
        tabs?,
        cli_args?,
        legacy_synchronize?,
        pre?,
        post?
      ]
    end

    def deprecation_messages
      [
        RBENVRVM_DEP_MSG,
        TABS_DEP_MSG,
        CLIARGS_DEP_MSG,
        SYNC_DEP_MSG,
        PRE_DEP_MSG,
        POST_DEP_MSG
      ]
    end

    def rbenv?
      yaml["rbenv"]
    end

    def rvm?
      yaml["rvm"]
    end

    def rvm_or_rbenv?
      rvm? || rbenv?
    end

    def tabs?
      yaml["tabs"]
    end

    def cli_args?
      yaml["cli_args"]
    end

    def pre?
      yaml["pre"]
    end

    def post?
      yaml["post"]
    end

    def get_pane_base_index
      tmux_config["pane-base-index"]
    end

    def get_base_index
      tmux_config["base-index"]
    end

    def show_tmux_options
      "#{tmux} start-server\\; " \
        "show-option -g base-index\\; " \
        "show-window-option -g pane-base-index\\;"
    end

    def tmux_new_session_command
      return if append?

      window = windows.first.tmux_window_name_option
      "#{tmux} new-session -d -s #{name} #{window}"
    end

    def tmux_kill_session_command
      "#{tmux} kill-session -t #{name}"
    end

    def enable_pane_titles?
      yaml["enable_pane_titles"]
    end

    def tmux_set_pane_title_position(tmux_window_target)
      command = set_window_option(tmux_window_target)
      if pane_title_position? && pane_title_position_valid?
        "#{command} pane-border-status #{yaml['pane_title_position']}"
      else
        "#{command} pane-border-status top"
      end
    end

    def tmux_set_pane_title_format(tmux_window_target)
      command = set_window_option(tmux_window_target)
      if pane_title_format?
        "#{command} pane-border-format \"#{yaml['pane_title_format']}\""
      else
        "#{command} pane-border-format \"\#{pane_index}: \#{pane_title}\""
      end
    end

    def pane_title_position_not_valid_warning
      print_warning(
        "The specified pane title position " +
        "\"#{yaml['pane_title_position']}\" is not valid. " +
        "Please choose one of: top, bottom, or off."
      )
    end

    def pane_titles_not_supported_warning
      print_warning(
        "You have enabled pane titles in your configuration, " +
        "but the feature is not supported by your version of tmux.\n" +
        "Please consider upgrading to a version that supports it (tmux >=2.6)."
      )
    end

    private

    def blank?(object)
      (object.respond_to?(:empty?) && object.empty?) || !object
    end

    def tmux_config
      @tmux_config ||= extract_tmux_config
    end

    def extract_tmux_config
      options_hash = {}

      `#{show_tmux_options}`.
        encode("UTF-8", invalid: :replace).
        split("\n").
        map do |entry|
        key, value = entry.split("\s")
        options_hash[key] = value
        options_hash
      end

      options_hash
    end

    def legacy_synchronize?
      (synchronize_options & [true, "before"]).any?
    end

    def synchronize_options
      window_options.map do |option|
        option["synchronize"] if option.is_a?(Hash)
      end
    end

    def window_options
      yaml["windows"].map(&:values).flatten
    end

    def parsed_parameters(parameters)
      parameters.is_a?(Array) ? parameters.join("; ") : parameters
    end

    def wemux?
      yaml["tmux_command"] == "wemux"
    end

    def pane_title_position?
      yaml["pane_title_position"]
    end

    def pane_title_position_valid?
      ["top", "bottom", "off"].include? yaml["pane_title_position"]
    end

    def pane_title_format?
      yaml["pane_title_format"]
    end

    def print_warning(message)
      yellow = '\033[1;33m'
      no_color = '\033[0m'
      msg = "WARNING: #{message}\n"
      "printf \"#{yellow}#{msg}#{no_color}\""
    end

    def set_window_option(tmux_window_target)
      "#{tmux} set-window-option -t #{tmux_window_target}"
    end
  end
end
