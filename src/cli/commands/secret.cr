module Meridian
  module CLI
    module Commands
      class Secret < GroupCommand
        def name : String
          "secret"
        end

        def summary : String
          "Manage Podman secrets per role"
        end

        def usage : String
          "Usage: meridian secret SUBCOMMAND NAME [options]"
        end

        def subcommand_summaries : Array({String, String})
          [
            {"gen", "Generate a random secret"},
            {"set", "Create or replace a secret on target hosts"},
            {"rm", "Remove a secret from target hosts"},
            {"ls", "List secrets on target hosts"},
          ]
        end

        def failure_message : String
          "Secret command failed"
        end
      end

      class SecretGen < Command
        @role = "web"
        @file = Meridian::Paths::CONFIG_FILE
        @force = false
        @print = false
        @length = 32
        @format = ::Meridian::Commands::Secret::GeneratedSecretFormat::Hex

        def name : String
          "secret gen"
        end

        def summary : String
          "Generate a random secret"
        end

        def usage : String
          "Usage: meridian secret gen NAME [options]"
        end

        def description : String
          String.build do |io|
            io.puts "Generate a random Podman secret on every host in the target role."
            io.print "--print emits the generated value locally without writing to remote hosts."
          end
        end

        def parse_positionals(args : Array(String)) : {Array(String), Array(String)}
          first = args.first?
          if first.nil? || first.starts_with?('-')
            {[] of String, args}
          else
            {[first], args.size > 1 ? args[1..] : [] of String}
          end
        end

        def configure(parser : OptionParser) : Nil
          parser.on("--length N", "Random byte length before encoding (default: 32)") { |v| @length = v.to_i }
          parser.on("--format FORMAT", "Encoding: hex, base64, base64url (default: hex)") do |v|
            @format = ::Meridian::Commands::Secret::GeneratedSecretFormat.parse(v)
          end
          parser.on("--print", "Print the generated value instead of storing it remotely") { @print = true }
          parser.on("--force", "Rotate an existing remote secret") { @force = true }
          parser.on("--role ROLE", "Target role (default: web)") { |v| @role = v }
          parser.on("--config PATH", "Path to deploy config (default: .meridian/deploy.yml)") { |v| @file = v }
        end

        def rescuable : Array(Exception.class)
          super + [ArgumentError, SSH::CommandFailed, SSH::ConnectionError, ::Meridian::Commands::SecretExists] of Exception.class
        end

        def failure_message : String
          "Secret command failed"
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          if positionals.empty?
            ctx.error.puts "Missing secret name"
            return 1
          end

          if @print && @force
            ctx.error.puts "--print and --force cannot be used together"
            return 1
          end

          if @print
            ctx.output.puts ::Meridian::Commands::Secret.generate_value(@length, @format)
            return 0
          end

          config = Config::Loader.load(@file)
          ::Meridian::Commands::Secret.new(config, ssh_executor: ctx.ssh_executor, output: ctx.output, error: ctx.error).gen(positionals.first, @role, @length, @format, @force)
          0
        end
      end

      class SecretSet < Command
        @value : String? = nil
        @role = "web"
        @file = Meridian::Paths::CONFIG_FILE

        def name : String
          "secret set"
        end

        def summary : String
          "Create or replace a secret on target hosts"
        end

        def usage : String
          "Usage: meridian secret set NAME [options]"
        end

        def description : String
          String.build do |io|
            io.puts "Create or replace a Podman secret on every host in the target role."
            io.print "Without --value: hidden terminal prompt with a character count, or piped stdin."
          end
        end

        def parse_positionals(args : Array(String)) : {Array(String), Array(String)}
          first = args.first?
          if first.nil? || first.starts_with?('-')
            {[] of String, args}
          else
            {[first], args.size > 1 ? args[1..] : [] of String}
          end
        end

        def configure(parser : OptionParser) : Nil
          parser.on("--value VALUE", "Secret value (default: prompt or stdin)") { |v| @value = v }
          parser.on("--role ROLE", "Target role (default: web)") { |v| @role = v }
          parser.on("--config PATH", "Path to deploy config (default: .meridian/deploy.yml)") { |v| @file = v }
        end

        def rescuable : Array(Exception.class)
          super + [ArgumentError, SSH::CommandFailed, SSH::ConnectionError] of Exception.class
        end

        def failure_message : String
          "Secret command failed"
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          if positionals.empty?
            ctx.error.puts "Missing secret name"
            return 1
          end

          config = Config::Loader.load(@file)
          secret_value = @value || read_secret_value(ctx, positionals.first)
          ::Meridian::Commands::Secret.new(config, ssh_executor: ctx.ssh_executor, output: ctx.output, error: ctx.error).set(positionals.first, secret_value, @role)
          0
        end

        protected def read_secret_value(ctx : Context, name : String) : String
          input = ctx.input
          return input.gets_to_end.chomp unless input.is_a?(IO::FileDescriptor) && input.tty?

          begin
            input.raw { read_hidden_value(input, ctx.error, name) }
          rescue IO::Error
            raise ArgumentError.new("Could not read hidden secret value")
          ensure
            ctx.error.puts
            ctx.error.flush
          end
        end

        protected def read_hidden_value(input : IO, error : IO, name : String) : String
          chars = [] of Char
          escape_state = 0
          loop do
            error.print "\rValue for #{name} (hidden): #{chars.size} characters\e[K"
            error.flush
            case char = input.read_char
            when nil, '\u0003', '\u0004'
              raise ArgumentError.new("Secret input cancelled")
            end

            if escape_state == 1
              escape_state = char.in?('[', 'O') ? 2 : 0
              next
            elsif escape_state == 2
              escape_state = 0 if char.in?('@'..'~')
              next
            end

            case char
            when '\r', '\n'
              raise ArgumentError.new("Secret value must not be empty") if chars.empty?
              return chars.join
            when '\b', '\u007f'
              chars.pop?
            when '\e'
              escape_state = 1
            else
              chars << char unless char.control?
            end
          end
        rescue InvalidByteSequenceError
          raise ArgumentError.new("Secret input must be valid UTF-8")
        end
      end

      class SecretRm < Command
        @role = "web"
        @file = Meridian::Paths::CONFIG_FILE

        def name : String
          "secret rm"
        end

        def summary : String
          "Remove a secret from target hosts"
        end

        def usage : String
          "Usage: meridian secret rm NAME [options]"
        end

        def description : String
          "Remove a Podman secret from every host in the target role."
        end

        def parse_positionals(args : Array(String)) : {Array(String), Array(String)}
          first = args.first?
          if first.nil? || first.starts_with?('-')
            {[] of String, args}
          else
            {[first], args.size > 1 ? args[1..] : [] of String}
          end
        end

        def configure(parser : OptionParser) : Nil
          parser.on("--role ROLE", "Target role (default: web)") { |v| @role = v }
          parser.on("--config PATH", "Path to deploy config (default: .meridian/deploy.yml)") { |v| @file = v }
        end

        def rescuable : Array(Exception.class)
          super + [ArgumentError, SSH::CommandFailed, SSH::ConnectionError] of Exception.class
        end

        def failure_message : String
          "Secret command failed"
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          if positionals.empty?
            ctx.error.puts "Missing secret name"
            return 1
          end

          config = Config::Loader.load(@file)
          ::Meridian::Commands::Secret.new(config, ssh_executor: ctx.ssh_executor, output: ctx.output, error: ctx.error).rm(positionals.first, @role)
          0
        end
      end

      class SecretLs < Command
        @role = "web"
        @file = Meridian::Paths::CONFIG_FILE

        def name : String
          "secret ls"
        end

        def summary : String
          "List secrets on target hosts"
        end

        def usage : String
          "Usage: meridian secret ls [options]"
        end

        def description : String
          "List Podman secrets on every host in the target role."
        end

        def configure(parser : OptionParser) : Nil
          parser.on("--role ROLE", "Target role (default: web)") { |v| @role = v }
          parser.on("--config PATH", "Path to deploy config (default: .meridian/deploy.yml)") { |v| @file = v }
        end

        def rescuable : Array(Exception.class)
          super + [ArgumentError, SSH::CommandFailed, SSH::ConnectionError] of Exception.class
        end

        def failure_message : String
          "Secret command failed"
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          config = Config::Loader.load(@file)
          ::Meridian::Commands::Secret.new(config, ssh_executor: ctx.ssh_executor, output: ctx.output, error: ctx.error).ls(@role)
          0
        end
      end
    end
  end
end
