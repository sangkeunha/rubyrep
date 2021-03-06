require 'drb'

module RR

  # This class represents a rubyrep session.
  # Creates and holds expensive objects like e. g. database connections.
  class Session
    
    # The Configuration object provided to the initializer
    attr_accessor :configuration
    
    # Returns the "left" ActiveRecord / proxy database connection
    def left
      @connections[:left]
    end
    
    # Stores the "left" ActiveRecord /proxy database connection
    def left=(connection)
      @connections[:left] = connection
    end
    
    # Returns the "right" ActiveRecord / proxy database connection
    def right
      @connections[:right]
    end
    
    # Stores the "right" ActiveRecord / proxy database connection
    def right=(connection)
      @connections[:right] = connection
    end
    
    # Hash to hold under either :left or :right the according Drb / direct DatabaseProxy
    attr_accessor :proxies

    # Creates a hash of manual primary key names as can be specified with the
    # Configuration options :+primary_key_names+ or :+auto_key_limit+.
    # * +db_arm: should be either :left or :right
    #
    # Returns the identified manual primary keys. This is a hash with
    # * key: table_name
    # * value: array of primary key names
    def manual_primary_keys(db_arm)
      manual_primary_keys = {}
      resolver = TableSpecResolver.new self
      table_pairs = resolver.resolve configuration.included_table_specs, [], false
      table_pairs.each do |table_pair|
        options = configuration.options_for_table(table_pair[:left])
        key_names = options[:key]
        if key_names == nil and options[:auto_key_limit] > 0
          if left.primary_key_names(table_pair[:left], :raw => true).empty?
            column_names = left.column_names(table_pair[:left])
            if column_names.size <= options[:auto_key_limit]
              key_names = column_names
            end
          end
        end
        if key_names
          table_name = table_pair[db_arm]
          manual_primary_keys[table_name] = [key_names].flatten
        end
      end
      manual_primary_keys
    end

    # Returns the corresponding table in the other database.
    # * +db_arm+: database of the given table (either :+left+ or :+right+)
    # * +table+: name of the table
    #
    # If no corresponding table can be found, return the given table.
    # Rationale:
    # Support the case where a table was dropped from the configuration but
    # there were still some unreplicated changes left.
    def corresponding_table(db_arm, table)
      unless @table_map
        @table_map = {:left => {}, :right => {}}
        resolver = TableSpecResolver.new self
        table_pairs = resolver.resolve configuration.included_table_specs, [], false
        table_pairs.each do |table_pair|
          @table_map[:left][table_pair[:left]] = table_pair[:right]
          @table_map[:right][table_pair[:right]] = table_pair[:left]
        end
      end
      @table_map[db_arm][table] || table
    end
    
    # Does the actual work of establishing a database connection
    # db_arm:: should be either :left or :right
    # config:: the rubyrep Configuration
    def db_connect(db_arm, config)
      arm_config = config.send db_arm
      @proxies[db_arm] = DatabaseProxy.new
      @connections[db_arm] = @proxies[db_arm].create_session arm_config
    end
    
    # Does the actual work of establishing a proxy connection
    # db_arm:: should be either :left or :right
    # config:: the rubyrep Configuration
    def proxy_connect(db_arm, config)
      arm_config = config.send db_arm
      if arm_config.include? :proxy_host 
        drb_url = "druby://#{arm_config[:proxy_host]}:#{arm_config[:proxy_port]}"
        @proxies[db_arm] = DRbObject.new nil, drb_url
      else
        # If one connection goes through a proxy, so has the other one.
        # So if necessary, create a "fake" proxy
        @proxies[db_arm] = DatabaseProxy.new
      end
      @connections[db_arm] = @proxies[db_arm].create_session arm_config
    end
    
    # True if proxy connections are used
    def proxied?
      [configuration.left, configuration.right].any? \
        {|arm_config| arm_config.include? :proxy_host}
    end

    # Returns an array of table pairs of the configured tables.
    # Refer to TableSpecResolver#resolve for a detailed description of the
    # return value.
    # If +included_table_specs+ is provided (that is: not an empty array), it
    # will be used instead of the configured table specs.
    def configured_table_pairs(included_table_specs = [])
      resolver = TableSpecResolver.new self
      included_table_specs = configuration.included_table_specs if included_table_specs.empty?
      resolver.resolve included_table_specs, configuration.excluded_table_specs
    end

    # Orders the array of table pairs as per primary key / foreign key relations
    # of the tables. Returns the result.
    # Only sorts if the configuration has set option :+table_ordering+.
    # Refer to TableSpecResolver#resolve for a detailed description of the
    # parameter and return value.
    def sort_table_pairs(table_pairs)
      if configuration.options[:table_ordering]
        left_tables = table_pairs.map {|table_pair| table_pair[:left]}
        sorted_left_tables = TableSorter.new(self, left_tables).sort
        sorted_left_tables.map do |left_table|
          table_pairs.find do |table_pair|
            table_pair[:left] == left_table
          end
        end
      else
        table_pairs
      end
    end

    # Refreshes (reestablish if no more active) the database connections.
    def refresh
      [:left, :right].each do |database|
        t = Thread.new {send(database).refresh}
        t.join configuration.options[:database_connection_timeout]
      end
    end
        
    # Creates a new rubyrep session with the provided Configuration
    def initialize(config = Initializer::configuration)
      @connections = {:left => nil, :right => nil}
      @proxies = {:left => nil, :right => nil}
      
      # Keep the database configuration for future reference
      self.configuration = config

      # Determine method of connection (either 'proxy_connect' or 'db_connect'
      connection_method = proxied? ? :proxy_connect : :db_connect
      
      # Connect the left database / proxy
      self.send connection_method, :left, configuration
      left.manual_primary_keys = manual_primary_keys(:left)
      
      # If both database configurations point to the same database
      # then don't create the database connection twice
      if configuration.left == configuration.right
        self.right = self.left
      else
        self.send connection_method, :right, configuration
        right.manual_primary_keys = manual_primary_keys(:right)
      end  
    end
  end
end
