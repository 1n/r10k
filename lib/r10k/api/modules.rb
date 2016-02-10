require 'r10k/api/errors'
require 'r10k/api/util'

require 'r10k/logging'

module R10K
  module API
    # Namespace containing R10K::API methods that interact primarily with one or more modules.
    # These methods are extended into the base R10K::API namespace and should only be called from that context.
    #
    # @api private
    module Modules
      extend R10K::Logging
      extend R10K::API::Util

      # Return a single module_source hashmap for the given module_name from the given env_map.
      #
      # @param module_name [String] The name of the module to build a module_source map for. Should match the "name" key of the target module in the env_map.
      # @param env_map [Hash] A hashmap representing a single environment's desired state.
      # @return [Hash] A hashmap representing the type (:vcs or :forge) and location of the given module's source.
      def module_source_for_module(module_name, env_map)
      end

      # Return an array of all remote sources referenced by module declarations within the given environment hashmap.
      #
      # @param env_map [Hash] A hashmap representing a single environment's state.
      # @return [Array<Hash>] An array of hashes, each hash represents the type (:vcs or :forge) and location of a single remote module source.
      def module_sources_for_environment(env_map)
        return env_map[:modules]
      end

      # Remove any deployed modules from the given path that do not exist in the given environment map.
      #
      # @param path [String] Path on disk to the deployed environment described by env_map.
      # @param env_map [Hash] An abstract or resolved environment map.
      # @return [true] Returns true on success, raises on failure.
      # @raise [RuntimeError]
      def purge_unmanaged_modules(path, env_map, opts={})
      end

      # Given a module_name and an env_map, resolve any ambiguity in the specified module's version. (All other modules in the env_map will be unchanged.)
      #
      # This function assumes that the relevant module cache has already been updated.
      #
      # @param module_name [String] Name of the module to be resolved, should match the value of the "name" key in the supplied environment map.
      # @param env_map [Hash] A hashmap representing a single environment's desired state.
      # @option opts [String] :cachedir Base path where caches are stored.
      # @option opts [Hash] :forge Additional options to control interaction with a Puppet Forge API implementation.
      # @option opts [Hash] :git Additional options to control interaction with remote Git repositories.
      # @return [Hash] A copy of env_map with a new :resolved_version key/value pair added for the specified module.
      # @raise [RuntimeError]
      # @raise [R10K::API::Errors::UnresolvableError]
      def resolve_module(module_name, env_map, opts={})
        # FIXME: Decide whether or not this is the right way to implement this still...
        # If it is, this method needs to be more consistent about returning a completely new instance of the env_map in all cases.

        mod_found = false

        env_map[:modules].map! do |mod|
          if mod[:name] == module_name
            mod = case mod[:type].to_sym
                  when :git
                    resolve_git_module(mod, opts)
                  when :forge
                    resolve_forge_module(mod, opts)
                  when :svn
                    raise NotImplementedError
                  when :local
                    raise NotImplementedError
                  else
                    raise Errors::UnresolvableError.new("Unable to resolve '#{module_name}', unrecognized module source type '#{mod[:type]}'.")
                  end

            mod_found = true
          end

          # We are mapping over the modules so we need let the module we just checked be the result of the block.
          mod
        end

        unless mod_found
          raise RuntimeError.new("Could not find module named '#{module_name}' in supplied environment map.")
        end

        return env_map
      end

      # Write the given module, using the version/commit declared in the given environment map, to disk at the given path.
      #
      # @param module_name [String] Name of the module to be written to disk, should match the value of the "name" key in the supplied environment map.
      # @param env_map [Hash] A fully-resolved (see {#resolve_environment}) hashmap representing a single environment's new state.
      # @param path [String] Path on disk into which the given module should be deployed. The given path should already include the environment and module names. (e.g. /puppet/environments/production/modules/apache) Path will be created if it does not already exist.
      # @option opts [String] :cachedir Base path where caches are stored.
      # @option opts [Hash] :forge Additional options to control interaction with a Puppet Forge API implementation.
      # @option opts [Hash] :git Additional options to control interaction with remote Git repositories.
      # @option opts [Boolean] :clean Remove untracked files in path after writing module?
      # @return [true] Returns true on success, raises on failure.
      # @raise [RuntimeError]
      def write_module(module_name, env_map, path, opts={})
        mod = env_map[:modules].find { |m| m[:name] == module_name }

        if mod.nil?
          raise RuntimeError.new("Could not find module named '#{module_name}' in supplied environment map.")
        end

        if !mod[:resolved_version]
          raise RuntimeError.new("Cannot write module '#{module_name}' from an environment map which is not fully resolved.")
        end

        if !File.directory?(path)
          FileUtils.mkdir_p(path)
        end

        # TODO: Safety/santity check on path?

        case mod[:type].to_sym
        when :git
          git_dir = cachedir_for_git_remote(mod[:source], opts[:cachedir])

          git.reset(path, mod[:resolved_version], git_dir: git_dir, hard: true)

          if opts[:clean]
            git.clean(path, git_dir: git_dir, force: true)
          end
        when :forge
          tarball_cachedir = cachedir_for_forge_module(mod[:source], opts[:cachedir])

          # TODO: cache tarball

          # TODO: use PuppetForge::Unpacker?
          raise NotImplementedError
        else
          raise NotImplementedError
        end

        return true
      end

      # Private class methods.
      # -----------------------------------------------------------------------

      def self.resolve_git_module(mod, opts={})
        if !opts[:cachedir]
          raise RuntimeError.new("A value is required for the :cachedir option when resolving module from a git source.")
        end

        cachedir = cachedir_for_git_remote(mod[:source], opts[:cachedir])

        begin
          mod[:resolved_version] = git.rev_parse(mod[:version], git_dir: cachedir)
        rescue R10K::Git::GitError => e
          raise Errors::UnresolvableError.new("Unable to resolve '#{mod[:version]}' to a valid Git commit for module '#{mod[:name]}'.")
        end

        return mod
      end
      private_class_method :resolve_git_module

      def self.resolve_forge_module(mod, opts={})
        # If the module is "unpinned" and not already deployed, resolve as "latest" but preserve declared value of "unpinned".
        if mod[:version].to_sym == :unpinned
          if !mod[:deployed_version]
            resolve_to = :latest
          else
            resolve_to = mod[:deployed_version]
          end
        end

        # FIXME: if somehow they have a deployed but unpinned module whose version doesn't exist on Forge, this will
        # currently fail to resolve

        begin
          # TODO: Filter out deleted releases?
          candidates = PuppetForge::V3::Module.find(mod[:source]).releases
        rescue Faraday::ResourceNotFound => e
          raise Errors::UnresolvableError.new("Unable to resolve '#{mod[:name]}', '#{mod[:source]}' could not be found on the Puppet Forge.")
        end

        if resolve_to == :latest || mod[:version].to_sym == :latest
          # Find first non-prerelease version
          match_release = candidates.find { |release| SemanticPuppet::Version.parse(release.version).prerelease.nil? }
        else
          # Find first version matching range
          desired = SemanticPuppet::VersionRange.parse(resolve_to || mod[:version])
          match_release = candidates.find { |release| desired.include?(SemanticPuppet::Version.parse(release.version)) }
        end

        if match_release
          mod[:resolved_version] = match_release.version
        else
          raise Errors::UnresolvableError.new("Unable to resolve '#{mod[:name]}', no released version of '#{mod[:source]}' could be found on the Puppet Forge which matches the version or range: '#{mod[:version]}'")
        end

        return mod
      end
      private_class_method :resolve_forge_module

    end
  end
end
