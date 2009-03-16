class VersionMigrationsGenerator < Rails::Generator::Base
  require 'yaml'
  
  #TODO: find all roots, not just the first.
    
  def manifest
    record do |m|
       return unless File.exists?("#{RAILS_ROOT}/config/deeply_versioned.yml")
       config = YAML.load_file("#{RAILS_ROOT}/config/deeply_versioned.yml") 
       models, settings = config["models"], config["settings"]
       @approved_models = models.map { |name, details| name }
       ActiveRecord::Base.timestamped_migrations = false
       models.each do |model|
          #TODO: make sure the user wants us to version this table!
          m.migration_template 'model:migration.rb', "db/migrate", 
            :assigns => versioned_local_assigns(model, settings),
            :migration_file_name => "create_#{model[0].downcase}_versions"
          m.migration_template 'migration:migration.rb', "db/migrate",
              :assigns => versionable_local_assigns(model, settings),
              :migration_file_name => "add_versionable_columns_to_#{model[0].downcase}"   
       end
       
       all_models = Dir.glob( File.join( RAILS_ROOT, 'app', 'models', '*.rb') ).map{|path| path[/.+\/(.+).rb/,1] }
       ar_models = all_models.select{|arm| arm.classify.constantize < ActiveRecord::Base}
       version_root = ar_models.find { |arm| arm.classify.constantize.version_root?  }.classify.constantize
       join_tables = traverse_tree(version_root.build_tree,[])
       
       join_tables.each do |table|
          m.migration_template 'model:migration.rb', "db/migrate",
            :assigns => table[:assigns],
            :migration_file_name => table[:file_name]
       end
       
    end
  end
  
  private
  
  def traverse_tree(tree, join_tables)
    tree.each_key do |key|
      key.constantize.downward_associations do |a|
        unless a.macro == :has_and_belongs_to_many && a.name.to_s.singularize.classify < key.to_s
          puts "possible join between #{key} & #{a.name.to_s.classify}"
          if @approved_models.include?(key) && @approved_models.include?(a.name.to_s.classify)
            puts "Yes!"
            table = {}
            table_name = key.tableize < a.name.to_s ? "#{key.tableize}_#{a.name.to_s}" : "#{a.name.to_s}_#{key.tableize}"
            table[:assigns] = returning(assigns = {}) do
              assigns[:table_name] = table_name
              assigns[:migration_name] = "create_#{table_name}"
              assigns[:attributes] = [Rails::Generator::GeneratedAttribute.new("#{key.downcase}_id", :integer)]
              assigns[:attributes] << Rails::Generator::GeneratedAttribute.new("#{a.name.to_s.singularize}_id", :integer)
            end
            table[:file_name] = "create_#{table_name}"
            join_tables << table
          end
        end
      end
      traverse_tree(tree[key], join_tables) unless tree[key].nil?
    end
    return join_tables
  end
  
  def versioned_local_assigns(model, settings)
    model_name = model[0]
    table_name = model_name.tableize 
    returning(assigns = {}) do
      assigns[:migration_name] = "create_#{model_name}_versions".camelize
      #TODO: table name should come out of config
      assigns[:table_name] = "#{model_name.downcase}_versions"
      assigns[:attributes] = []
      model[1]["attributes"].each do |key, value|
          #TODO: make sure the user wants us to version this column!!
          assigns[:attributes] << Rails::Generator::GeneratedAttribute.new(key, fetch_type(model_name, key))
      end
      assigns[:attributes] << Rails::Generator::GeneratedAttribute.new(settings["version_column"], :integer) if model[0].constantize.version_root?   
    end
  end
  
  def versionable_local_assigns(model, settings)
    model_name = model[0]
    table_name = model_name.tableize
    returning(assigns = {}) do
       assigns[:migration_action] = "add"
       assigns[:table_name] = table_name
       assigns[:class_name] = "add_versionable_columns_to_#{table_name}"
       assigns[:attributes]  = [Rails::Generator::GeneratedAttribute.new(settings["version_root_column_name"], :string)]
       assigns[:attributes]  << Rails::Generator::GeneratedAttribute.new(settings["version_column"], :integer) if model[0].constantize.version_root?
       
    end
  end
  
  def fetch_type(model_name, attribute)
      puts "fetch_type: #{model_name.classify.constantize.columns.find { |c| c.name == attribute}.type}"
      model_name.classify.constantize.columns.find { |c| c.name == attribute}.type
  end
  
end