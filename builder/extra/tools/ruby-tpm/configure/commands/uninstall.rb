class UninstallClusterCommand
  include ConfigureCommand
  include RemoteCommand
  include ClusterCommandModule
  
  def initialize(config)
    super(config)
    @skip_prompts = true
    @confirmation_flag_found = false
    distribute_log?(false)
  end
  
  def allow_command_line_cluster_options?
    false
  end
  
  def confirmation_flag_found?(v = nil)
    if v != nil
      @confirmation_flag_found = v
    end
    
    return @confirmation_flag_found
  end
  
  def parsed_options?(arguments)
    arguments = super(arguments)
    
    if display_help?() && !display_preview?()
      return arguments
    end
    
    opts=OptionParser.new
    opts.on("--i-am-sure") { confirmation_flag_found?(true) }
    
    remainder = Configurator.instance.run_option_parser(opts, arguments)
    
    unless confirmation_flag_found?()
      error("You must add '--i-am-sure' to the command in order to complete the uninstall")
    end
    
    return remainder
  end
  
  def get_validation_checks
    [
      CurrentReleaseDirectoryWarning.new()
    ]
  end
  
  def get_deployment_object_modules(config)
    [
      UninstallClusterDeploymentStep
    ]
  end
  
  def use_remote_package?
    true
  end
  
  def get_default_remote_package_path
    false
  end
  
  def self.display_command
    false
  end
  
  def self.get_command_name
    'uninstall'
  end
  
  def self.get_command_description
    "Uninstall Tungsten on each host"
  end
end

module UninstallClusterDeploymentStep
  def get_methods
    [
      ConfigureCommitmentMethod.new("stop_services", -1, 0),
      ConfigureCommitmentMethod.new("delete_tungsten", 0, 0)
    ]
  end
  module_function :get_methods
  
  def delete_tungsten
    undeployall_script = "#{@config.getProperty(CURRENT_RELEASE_DIRECTORY)}/cluster-home/bin/undeployall >/dev/null 2>&1"
    begin
      Timeout.timeout(5) do
        cmd_result(undeployall_script, true)
      end
    rescue Timeout::Error
      warning("Unable to run #{undeployall_script}")
    end
    
    if is_replicator?()
      # Start the replicator in OFFLINE mode so we can reset services
      replicator_started = false
      begin
        cmd_result("#{@config.getProperty(CURRENT_RELEASE_DIRECTORY)}/tungsten-replicator/bin/replicator start offline")
        replicator_started = true
      rescue CommandError
      end
      
      Configurator.instance.command.build_topologies(@config)
      @config.getPropertyOr([REPL_SERVICES], {}).each_key{
        |rs_alias|
        if rs_alias == DEFAULTS
          next
        end
        
        rs_name = @config.getProperty([REPL_SERVICES, rs_alias, DEPLOYMENT_SERVICE])
        ds = get_applier_datasource(rs_alias)
        if ds.is_a?(MySQLDatabasePlatform)
          mysql_result = ds.get_value("select @@read_only")
          if mysql_result == nil
            mysql_start_command = @config.getProperty([REPL_SERVICES, rs_alias, REPL_DBSERVICE_START])
            mysql_result = start_mysql_server(mysql_start_command, ds)
            if mysql_result == "1"
              warning("MySQL is configured to start in read_only mode, this can cause problems with Tungsten installation - please check for 'read_only' in the MySQL configuration file and startup command")
            end
          end
          if mysql_result == "1"
            ds.run("set global read_only=0")
          end
        end
        
        if replicator_started == true
          begin
            cmd_result("#{@config.getProperty(CURRENT_RELEASE_DIRECTORY)}/tungsten-replicator/bin/trepctl -service #{rs_name} reset -all -y")
          rescue CommandError
            warning("There was a problem resetting the #{rs_name} replication service")
          end
        else
          warning("Unable to reset the #{rs_name} replication service")
        end
        
        [
          @config.getProperty([REPL_SERVICES, rs_alias, REPL_BACKUP_STORAGE_DIR]),
          @config.getProperty([REPL_SERVICES, rs_alias, REPL_RELAY_LOG_DIR]),
          @config.getProperty([REPL_SERVICES, rs_alias, REPL_LOG_DIR])
        ].each{
          |dir|
          # Don't delete the base directory if it's not under the home
          # directory. This prevents deleting a symlink or special path
          if dir =~ /#{@config.getProperty(HOME_DIRECTORY)}/
            FileUtils.rmtree(dir)
          else
            FileUtils.rmtree(Dir.glob(dir + "/*"))
          end
        }
        
        trigger_event(:uninstall_replication_service, rs_alias)
      }
      
      if replicator_started == true
        cmd_result("#{@config.getProperty(CURRENT_RELEASE_DIRECTORY)}/tungsten-replicator/bin/replicator stop")
      end
    end
    
    # Only remove the files in the share directory that we put in place
    Dir.glob("#{@config.getProperty(HOME_DIRECTORY)}/share/.*.orig").each{
      |file|
      original_dir = File.dirname(file)
      original_filename = File.basename(file)
      
      match = original_filename.match(/\.(.*)\.orig/)
      if match != nil
        watched_filename = match[1]
        debug("Remove #{watched_filename} and #{original_filename}")
        FileUtils.rm_f("#{original_dir}/#{watched_filename}")
        FileUtils.rm_f("#{original_dir}/#{original_filename}")
      else
        debug("Unable to find a watched file for #{original_filename}")
      end
    }
    
    if File.exist?("#{@config.getProperty(HOME_DIRECTORY)}/share/mysql-connector-java.jar")
      Configurator.instance.debug("Remove MySQL Connector/J")
      linked = File.readlink("#{@config.getProperty(HOME_DIRECTORY)}/share/mysql-connector-java.jar")
      FileUtils.rm_f(linked)
      FileUtils.rm_f("#{@config.getProperty(HOME_DIRECTORY)}/share/mysql-connector-java.jar")
    end
    
    # Look for the deployed files for each of these and delete if present
    [JAVA_TLS_KEYSTORE_PATH, JAVA_JGROUPS_KEYSTORE_PATH].each {
      |key|
      source_file = @config.getProperty(key)
      target_file = @config.getTemplateValue(key)
      
      if source_file == target_file
        # Do not delete the file because it was provided to the installation
        next
      end
      
      if File.exist?(target_file)
        Configurator.instance.debug("Remove #{target_file}")
        File.unlink(target_file)
      end
    }

    Configurator.instance.debug("Remove home directory contents")
    FileUtils.rmtree("#{@config.getProperty(HOME_DIRECTORY)}/#{LOGS_DIRECTORY_NAME}")
    FileUtils.rmtree("#{@config.getProperty(HOME_DIRECTORY)}/#{METADATA_DIRECTORY_NAME}")
    FileUtils.rmtree(@config.getProperty(CONFIG_DIRECTORY))
    FileUtils.rmtree(@config.getProperty(LOGS_DIRECTORY))
    FileUtils.rmtree(@config.getProperty(REPL_METADATA_DIRECTORY))
    FileUtils.rmtree(@config.getProperty(METADATA_DIRECTORY))
    FileUtils.rmtree(@config.getProperty(RELEASES_DIRECTORY))
    FileUtils.rmtree(@config.getProperty(CURRENT_RELEASE_DIRECTORY))
  end
  
  def start_mysql_server(mysql_start_command, ds)
    notice("Start the MySQL service")
    begin
      cmd_result("sudo -n #{mysql_start_command} start")
    rescue CommandError
    end

    # Wait 30 seconds for the MySQL service to be responsive
    begin
      Timeout.timeout(30) {
        while true
          begin
            mysql_result = ds.get_value("select @@read_only")
            if mysql_result != nil
              return mysql_result
            end

            # Pause for a second before running again
            sleep 1
          rescue
          end
        end
      }
    rescue Timeout::Error
      raise "The MySQL server has taken too long to start"
    end
  end
end

class CurrentReleaseDirectoryWarning < ConfigureValidationCheck
  include LocalValidationCheck
  
  def set_vars
    @title = "Current release directory"
  end
  
  def validate
    validation_directory = @config.getProperty(CURRENT_RELEASE_DIRECTORY)
    debug "Checking #{validation_directory}"
    
    user = @config.getProperty(USERID)
    
    # The -D flag will tell us if it is a directory
    is_directory = ssh_result("if [ -d #{validation_directory} ]; then echo 0; else echo 1; fi", @config.getProperty(HOST), user)
    unless is_directory == "0"
      warning "#{validation_directory} does not exist"
    else
      debug "#{validation_directory} exists"
    end
  end
end

class CurrentReleaseDirectoryCheck < ConfigureValidationCheck
  include LocalValidationCheck
  
  def set_vars
    @title = "Current release directory"
  end
  
  def validate
    validation_directory = @config.getProperty(CURRENT_RELEASE_DIRECTORY)
    debug "Checking #{validation_directory}"
    
    user = @config.getProperty(USERID)
    
    # The -D flag will tell us if it is a directory
    is_directory = ssh_result("if [ -d #{validation_directory} ]; then echo 0; else echo 1; fi", @config.getProperty(HOST), user)
    unless is_directory == "0"
      error "#{validation_directory} does not exist"
    else
      debug "#{validation_directory} exists"
    end
  end
end
