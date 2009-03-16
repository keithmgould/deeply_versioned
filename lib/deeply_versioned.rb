module DeeplyVersioned
  module AllModelMethods
    def is_deeply_versioned
      @version_root = true
      send :extend, DeeplyVersioned::VersionableModelMethods
      send :include, DeeplyVersioned::VersionableInstanceMethods
      create_versioned_system_node
    end
  
    def version_root?
      @version_root.nil? ? false : @version_root
    end
    
  end
  
  module VersionableModelMethods
    require 'yaml'
    
    def visited?
      @visited.nil? ? false : @visited
    end
    
    def downward_associations
      self.reflect_on_all_associations.each do |a|
        if (a.macro == :has_many) || (a.macro == :has_one) || (a.macro == :has_and_belongs_to_many)
          #TODO: make "versions" based on what is in config file, not static
          if (a.name.to_s != "versions")
              yield a
          end
        end
      end  
    end

    #used for rake tasks and migration        
    def build_versionable_list
      model_list = []
      unless visited?
        model_list << self
        @visited = true
        downward_associations do |a| 
          model_list += a.name.to_s.singularize.capitalize.constantize.build_versionable_list
        end
      end
      @visited = false
      return model_list
    end
    
    def build_tree
      tree = {}
      unless visited?
        @visited = true
        downward_associations do |a| 
          tree[self.to_s] = a.name.to_s.singularize.capitalize.constantize.build_tree
        end 
      end
      @visited = false
      return tree.size > 0 ? tree : nil
    end

    def create_versioned_system_node
      Rails.logger.debug "in cvsn for #{self.class.to_s}"
      config_path = "#{RAILS_ROOT}/config/deeply_versioned.yml"
      @config = YAML.load_file(config_path) if File.exists?(config_path)
      unless visited?
        @visited = true           
        create_dynamic_version_model
        downward_associations do |a|
              Rails.logger.debug "in #{a.name.to_s}"
              #TODO: check to make sure the child table should be versioned
              if version_this_table? a.name
                a.name.to_s.singularize.capitalize.constantize.send :extend, DeeplyVersioned::VersionableModelMethods
                a.name.to_s.singularize.capitalize.constantize.send :include, DeeplyVersioned::VersionableInstanceMethods
                a.name.to_s.singularize.capitalize.constantize.create_versioned_system_node
              end
        end
      end
      @visited = false
      return 0
    end
       
    #TODO: the answer comes from the yml file 
    def version_this_table?(table_name)
      return true
    end

    #TODO: these options should be coming from the yml file, not hard coded.
    def create_dynamic_version_model(options = {})
      cattr_accessor  :versioned_class_name,
                      :versioned_foreign_key, 
                      :versioned_table_name,
                      :root_column,
                      :non_versioned_columns,
                      :version_association_options
      cattr_accessor  :version_column if version_root?

      self.versioned_class_name           = "Version"
      self.versioned_foreign_key          = self.to_s.foreign_key
      self.versioned_table_name           = "#{table_name_prefix}#{base_class.name.demodulize.underscore}_versions#{table_name_suffix}"
      self.version_column                 = 'version' if version_root?
      self.root_column                    = 'version_root_id'
      self.non_versioned_columns          = [self.primary_key, self.root_column ]
      self.non_versioned_columns          << self.version_column if version_root?
      self.version_association_options    = { :class_name  => "#{self.to_s}::#{versioned_class_name}",
                                              :foreign_key => versioned_foreign_key,
                                              :dependent   => :delete_all }
      
      const_set(versioned_class_name, Class.new(ActiveRecord::Base))
      versioned_class.cattr_accessor :original_class
      versioned_class.original_class = self
      versioned_class.set_table_name versioned_table_name
      versioned_class.belongs_to self.to_s.demodulize.underscore.to_sym, 
         :class_name  => "::#{self.to_s}", 
         :foreign_key => versioned_foreign_key
         
      Rails.logger.debug "Working on #{self.to_s}"          
      
      class_eval do
        has_many :versions , version_association_options do
            # finds earliest version of this record
            def earliest
              @earliest ||= find(:first, :order => "#{original_class.version_column}")
            end
      
            # find latest version of this record
            def latest
              @latest ||= find(:first, :order => "#{original_class.version_column} desc")
            end
        end
      end
      
      # Well, I'm using an observer. I know this is more appropriate
      # but sheesh, it feels like a lot of extra code.
      const_set("VersionedObserver", Class.new(ActiveRecord::Observer)).class_eval do
        observe self.parent.to_s.downcase.to_sym
        def after_save(model)
          Rails.logger.debug "you are so totally observed."
        end
      end 
      ActiveRecord::Base.observers = [self::VersionedObserver]
      ActiveRecord::Base.instantiate_observers
      
       
    end
    
    # Returns an array of columns that are versioned.  See non_versioned_columns
    def versioned_columns
      @versioned_columns ||= columns.select { |c| !non_versioned_columns.include?(c.name) }
    end
    
    def versioned_class
      const_get versioned_class_name
    end

  end
  
  module VersionableInstanceMethods
    
    def version_root?
      self.class.version_root?
    end
    
    def system_root_id
      self.send self.class.root_column
    end
              
    def before_create
      self.version = 1 if version_root?
    end

    def before_update
      self.version += 1 if version_root?
    end
    
    def update_children
      self.class.downward_associations do |a|
        children = send a.name.to_s, true
        children.each do |child|
            child.reload
            if child.version != self.version
              writable_child = child.readonly? ? a.class_name.constantize.find_by_id(child.id) : child
              writable_child.version = self.version
              writable_child.send "#{self.class.root_column}=", self.system_root_id
              writable_child.skip_top = true
              writable_child.save
            end
        end
      end
    end        
    
    def save_version
      Rails.logger.debug "#{ self.class.human_name } going to save version #{version} of itself."
      rev = self.class.versioned_class.new
      clone_versioned_model(self,rev)
      Rails.logger.debug "self.class.version_column: #{self.class.version_column}"
      rev.send("#{self.class.version_column}=", send(self.class.version_column))
      rev.send("#{self.class.versioned_foreign_key}=", id)
      rev.save
    end
    
    # Clones a model.  Used when saving a new version or reverting a model's version.
    def clone_versioned_model(orig_instance, rev_instance)
      self.class.versioned_columns.each do |col|
        Rails.logger.debug "copying over #{col.name}"
        rev_instance.send("#{col.name}=", orig_instance.send(col.name)) if orig_instance.has_attribute?(col.name) && rev_instance.has_attribute?(col.name)
      end
      
      #set created_at = first version's created at
      #rev_instance.created_at = rev.class.send 
                
    end
  end
end
ActiveRecord::Base.send :extend, DeeplyVersioned::AllModelMethods