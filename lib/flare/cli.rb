# frozen_string_literal: true

require_relative "version"

module Flare
  module CLI
    COMMANDS = {
      "setup" => "Authenticate and configure Flare for this project",
      "doctor" => "Check your Flare setup for issues",
      "status" => "Show current Flare configuration",
      "version" => "Print the Flare version",
      "help" => "Show this help message",
    }.freeze

    def self.start(argv)
      command = argv.first

      case command
      when "setup"
        require_relative "cli/setup_command"
        force = argv.include?("--force")
        SetupCommand.new(force: force).run
      when "doctor"
        require_relative "cli/doctor_command"
        DoctorCommand.new.run
      when "status"
        require_relative "cli/status_command"
        StatusCommand.new.run
      when "version", "-v", "--version"
        puts "flare #{Flare::VERSION}"
      when "help", nil, "-h", "--help"
        print_help
      else
        $stderr.puts "Unknown command: #{command}"
        $stderr.puts
        print_help
        exit 1
      end
    end

    def self.print_help
      puts "Usage: flare <command>"
      puts
      puts "Commands:"
      COMMANDS.each do |name, description|
        puts "  %-12s %s" % [name, description]
      end
    end
  end
end
