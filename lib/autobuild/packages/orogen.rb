module Autobuild
    def self.orogen(opts, &proc)
        Orogen.new(opts, &proc)
    end

    # This class represents packages generated by orogen. oroGen is a
    # specification and code generation tool for the Orocos/RTT integration
    # framework. See http://rock-robotics.org for more information.
    #
    # This class extends the CMake package class to handle the code generation
    # step. Moreover, it will load the orogen specification and automatically
    # add the relevant pkg-config dependencies as dependencies.
    #
    # This requires that the relevant packages define the pkg-config definitions
    # they install in the pkgconfig/ namespace. It means that a "driver/camera"
    # package (for instance) that installs a "camera.pc" file will have to
    # provide the "pkgconfig/camera" virtual package. This is done automatically
    # by the CMake package handler if the source contains a camera.pc.in file,
    # but can also be done manually with a call to Package#provides:
    #
    #   pkg.provides "pkgconfig/camera"
    #
    class Orogen < CMake
        class << self
            attr_accessor :corba

            # If set to true, all components are generated with the
            # --extended-states option
            #
            # The default is false
            attr_accessor :extended_states

            # See #always_regenerate?
            attr_writer :always_regenerate

            # If true (the default), the oroGen component will be regenerated
            # every time a dependency is newer than the package itself.
            #
            # Otherwise, autobuild tries to regenerate it only when needed
            #
            # This is still considered experimental. Use
            # Orogen.always_regenerate= to set it
            def always_regenerate?
                @always_regenerate
            end
        end

        @always_regenerate = true

        @orocos_target = nil

        # The target that should be used to generate and build orogen components
        def self.orocos_target
            user_target = ENV['OROCOS_TARGET']
            if @orocos_target
                @orocos_target.dup
            elsif user_target && !user_target.empty?
                user_target
            else
                'gnulinux'
            end
        end

        class << self
            attr_accessor :default_type_export_policy
            # The list of enabled transports as an array of strings (default:
            # typelib, corba)
            attr_reader :transports

            attr_reader :orogen_options
        end
        @orogen_options = []
        @default_type_export_policy = :used
        @transports = %w[corba typelib mqueue]
        @rtt_scripting = true

        attr_reader :orogen_options

        # The path to the orogen tool as resolved from {Package#full_env}
        attr_reader :orogen_tool_path

        # Overrides the global Orocos.orocos_target for this particular package
        attr_writer :orocos_target

        # The orocos target that should be used for this particular orogen
        # package
        #
        # By default, it is the same than Orogen.orocos_target. It can be set by
        # doing
        #
        #   package.orocos_target = 'target_name'
        def orocos_target
            if @orocos_target.nil?
                Orogen.orocos_target
            else
                @orocos_target
            end
        end

        attr_writer :corba, :orogen_file

        def corba
            @corba || (@corba.nil? && Orogen.corba)
        end

        # Overrides the global Orocos.extended_states for this particular package
        attr_writer :extended_states

        def extended_states
            @extended_states || (@extended_states.nil? && Orogen.extended_states)
        end

        # Path to the orogen file used for this package
        #
        # If not set, the class will look for a .orogen file in the package
        # source directory. It will return nil if the package is not checked out
        # yet, and raise ArgumentError if the package is indeed present but no
        # orogen file can be found
        #
        # It can be explicitely set with #orogen_file=
        def orogen_file
            if @orogen_file
                @orogen_file
            else
                return unless File.directory?(srcdir)

                Dir.glob(File.join(srcdir, '*.orogen')) do |path|
                    return File.basename(path)
                end
                raise ArgumentError,
                      "cannot find an oroGen specification file in #{srcdir}"
            end
        end

        def initialize(*args, &config)
            super

            @orogen_tool_path = nil
            @orogen_version = nil
            @orocos_target = nil
            @orogen_options = []
        end

        def prepare_for_forced_build
            super
            FileUtils.rm_f genstamp
        end

        def update_environment
            super
            typelib_plugin = File.join(prefix, 'share', 'typelib', 'ruby')
            env_add_path 'TYPELIB_RUBY_PLUGIN_PATH', typelib_plugin
        end

        # The version of orogen, given as a string
        #
        # It is used to enable/disable some configuration features based on the
        # orogen version string
        def orogen_version
            if !@orogen_version && (root = orogen_root)
                version_file = File.join(root, 'lib', 'orogen', 'version.rb')
                version_line = File.readlines(version_file).grep(/VERSION\s*=\s*"/).first
                @orogen_version = $1 if version_line =~ /.*=\s+"(.+)"$/
            end
            @orogen_version
        end

        def orogen_root
            if orogen_tool_path
                root = File.expand_path(File.join('..', '..'), orogen_tool_path)
                root if File.directory?(File.join(root, 'lib', 'orogen'))
            end
        end

        def prepare
            file configurestamp => genstamp
            stamps = dependencies.map { |pkg| Autobuild::Package[pkg].installstamp }

            file genstamp => [*stamps, source_tree(srcdir)] do
                isolate_errors { regen }
            end

            with_doc

            super
        end

        def genstamp
            File.join(srcdir, '.orogen', 'orogen-stamp')
        end

        def add_cmd_to_cmdline(cmd, cmdline)
            if cmd =~ /^([\w-]+)$/
                cmd_filter = $1
            else
                cmdline << cmd
                return
            end

            cmdline.delete_if { |str| str =~ /^#{cmd_filter}/ }
            if cmd_filter =~ /^--no-(.*)/
                cmd_filter = $1
                cmdline.delete_if { |str| str =~ /^--#{cmd_filter}/ }
            end
            cmdline << cmd
        end

        def regen
            cmdline = []
            cmdline << '--corba' if corba

            ext_states = extended_states
            unless ext_states.nil?
                cmdline.delete_if { |str| str =~ /extended-states/ }
                cmdline <<
                    if ext_states
                        '--extended-states'
                    else
                        '--no-extended-states'
                    end
            end

            unless (@orogen_tool_path = find_in_path('orogen'))
                raise ArgumentError, "cannot find 'orogen' in #{resolved_env['PATH']}"
            end

            unless (version = orogen_version)
                raise ArgumentError, "cannot determine the orogen version"
            end

            if version >= "1.0" # rubocop:disable Style/IfUnlessModifier
                cmdline << "--parallel-build=#{parallel_build_level}"
            end
            if version >= "1.1"
                cmdline << "--type-export-policy=#{Orogen.default_type_export_policy}"
                cmdline << "--transports=#{Orogen.transports.sort.uniq.join(',')}"
            end

            # Now, add raw options
            #
            # The raw options take precedence
            Orogen.orogen_options.each do |cmd|
                add_cmd_to_cmdline(cmd, cmdline)
            end
            orogen_options.each do |cmd|
                add_cmd_to_cmdline(cmd, cmdline)
            end

            cmdline = cmdline.sort
            cmdline << orogen_file

            needs_regen = Autobuild::Orogen.always_regenerate?

            # Try to avoid unnecessary regeneration as generation can be pretty
            # long
            #
            # First, check if the command line changed
            needs_regen ||=
                if File.exist?(genstamp)
                    last_cmdline = File.read(genstamp).split("\n")
                    last_cmdline != cmdline
                else
                    true
                end

            # Then, if it has already been built, check what the check-uptodate
            # target says
            needs_regen ||= !generation_uptodate?

            if needs_regen
                progress_start "generating oroGen %s",
                               done_message: 'generated oroGen %s' do
                    in_dir(srcdir) do
                        run 'orogen', Autobuild.tool('ruby'), '-S',
                            orogen_tool_path, *cmdline
                        File.open(genstamp, 'w') do |io|
                            io.print cmdline.join("\n")
                        end
                    end
                end
            else
                message "no need to regenerate the oroGen project %s"
                Autobuild.touch_stamp genstamp
            end
        end

        def generation_uptodate?
            if !File.file?(genstamp)
                true
            elsif File.file?(File.join(builddir, 'Makefile'))
                make = Autobuild.tool('make')
                system("#{make} -C #{builddir} check-uptodate > /dev/null 2>&1")
            else
                true
            end
        end
    end
end
