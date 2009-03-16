namespace :deeply_versioned do

  desc "generate YML config file."
  task (:generate_config => :environment) do
    require 'yaml'
    
    settings = {}
    settings["version_table_suffix"] = "_versions"
    settings["version_root_column_name"] = "version_root"
    settings["version_column"] = "version"

    #TODO: this needs to recognize all version_roots, not just the first one
    all_models = Dir.glob( File.join( RAILS_ROOT, 'app', 'models', '*.rb') ).map{|path| path[/.+\/(.+).rb/,1] }
    ar_models = all_models.select{|arm| arm.classify.constantize < ActiveRecord::Base}
    version_root = ar_models.find { |arm| arm.classify.constantize.version_root?  }.classify.constantize
    tables = {}
    versionable_list = version_root.build_versionable_list
    versionable_list.each do |vm|
      table = { "version_this_model" => true }
      skip_columns = ["id", "version", "version_root_id", "#{vm.to_s.downcase}_version"]
      #we don't need foreign keys
      skip_columns += versionable_list.map { |model| "#{model.to_s.downcase}_id"}
      columns = {}
      vm.columns.each { |c| columns[c.name] = true unless skip_columns.include? c.name }
      #table["system_root"] = true if vm == version_root
      table["attributes"] = columns
      tables[vm.to_s] = table
    end
    #tables.merge!(traverse_tree(version_root.build_tree, {}))
    #TODO: Get instructional comments into the config file
    file = File.open("#{RAILS_ROOT}/config/deeply_versioned.yml", "w") do |f|
      YAML.dump({ "settings" => settings, "models" => tables}, f)
    end
  end

  def traverse_tree(tree, join_tables)
    tree.each_key do |key|
      key.constantize.downward_associations do |a|
        unless a.macro == :has_and_belongs_to_many && a.name.to_s.singularize.classify < key.to_s
          table_name = key.tableize < a.name.to_s ? "#{key.tableize}_#{a.name.to_s}" : "#{a.name.to_s}_#{key.tableize}"
          columns = {"#{key.downcase}_id" => true, "#{a.name.to_s.singularize.downcase}_id" => true}
          table = {"columns" => columns, "version_this_join_table" => true}
          join_tables[table_name] = table
        end
      end
      traverse_tree(tree[key], join_tables) unless tree[key].nil?
    end
    return join_tables
  end

end