module HydraAttribute
  class HydraValue

    # This error is raised when +:hydra_attribute_id+ key isn't passed to initialize.
    # This key is important for determination the type of attribute which this model represents.
    class HydraAttributeIdIsMissedError < ArgumentError
      def initialize(msg = 'Key :hydra_attribute_id is missed')
        super
      end
    end

    # This error is raised when <tt>HydraAttribute::HydraValue</tt> model is saved
    # but <tt>entity model</tt> isn't persisted
    class EntityModelIsNotPersistedError < RuntimeError
      def initialize(msg = 'HydraValue model cannot be saved is entity model is not persisted')
        super
      end
    end

    include ::HydraAttribute::Model::IdentityMap
    include ActiveModel::AttributeMethods
    include ActiveModel::Dirty

    attr_reader :entity, :value_id, :value_type

    define_attribute_method :value
    define_attribute_method :value_id
    define_attribute_method :value_type

    # Initialize hydra value object
    #
    # @param [ActiveRecord::Base] entity link to entity model
    # @param [Hash] attributes contain values of table row
    # @option attributes [Symbol] :id
    # @option attributes [Symbol] :hydra_attribute_id this field is required
    # @option attributes [Symbol] :value
    def initialize(entity, attributes = {})
      raise HydraAttributeIdIsMissedError unless attributes.has_key?(:hydra_attribute_id)
      @entity     = entity
      @attributes = attributes
      if column.sql_type == "enum"
        if column.type_cast(attributes[:value]).nil?
          @value = nil
        else
          @value = attributes[:value].to_json
        end
      elsif attributes.has_key?(:value)
        @value = column.type_cast(attributes[:value])
      elsif attributes.has_key?(:value_id) && attributes.has_key?(:value_type)
        @value_id = column.type_cast(attributes[:value_id])
        @value_type = column.type_cast(attributes[:value_type])
      else
        @value = column.type_cast(column.default)
        attributes[:value] = column.default
      end
    end

    class << self
      # Holds <tt>Arel::Table</tt> objects grouped by entity table and backend type of attribute
      #
      # @return [Hash]
      def arel_tables
        @arel_tables ||= Hash.new do |entity_tables, entity_table|
          entity_tables[entity_table] = Hash.new do |backend_types, backend_type|
            backend_types[backend_type] = Arel::Table.new("hydra_#{backend_type}_#{entity_table}", ::ActiveRecord::Base)
          end
        end
      end

      # Returns database adapter
      #
      # @return [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      def connection
        ::ActiveRecord::Base.connection
      end

      # Returns virtual value column
      #
      # @param [Fixnum] hydra_attribute_id
      # @return [ActiveRecord::ConnectionAdapters::Column]
      def column(hydra_attribute_id)
        nested_identity_map(:column).cache(hydra_attribute_id.to_i) do
          hydra_attribute = ::HydraAttribute::HydraAttribute.find(hydra_attribute_id)
          ::ActiveRecord::ConnectionAdapters::Column.new(hydra_attribute.name, hydra_attribute.default_value, hydra_attribute.backend_type)
        end
      end

      # Delete all values for current entity
      #
      # @param [HydraAttribute::HydraEntity] entity
      # @return [NilClass]
      def delete_entity_values(entity)
        hydra_attributes = ::HydraAttribute::HydraAttribute.all_by_entity_type(entity.class.name)
        hydra_attributes = hydra_attributes.group_by(&:backend_type)
        hydra_attributes.each do |backend_type, attributes|
          table = arel_tables[entity.class.table_name][backend_type]
          where = table['hydra_attribute_id'].in(attributes.map(&:id)).and(table['entity_id'].eq(entity.id))
          arel  = table.from(table)
          connection.delete(arel.where(where).compile_delete, 'SQL')
        end
      end
    end

    # Returns virtual value column
    #
    # @return [ActiveRecord::ConnectionAdapters::Column]
    def column
      self.class.column(@attributes[:hydra_attribute_id])
    end

    # Returns model ID
    #
    # @return [Fixnum]
    def id
      @attributes[:id]
    end
    
    def value
      if column.sql_type == "polymorphic_association"
        polymorphic_value
      elsif column.sql_type == "enum"
        if @value.is_a?(Array) || @value.is_a?(Hash)
          @value
        else
          YAML.load value_before_type_cast if value_before_type_cast
        end
      else
        @value
      end
    end
      
    # Returns object for polymorphic association
    #
    # @return ActiveRecord::Base object
    def polymorphic_value
      @value_type.constantize.find(@value_id) if @value_type.present? && @value_id.present?
    end
    


    # Sets new type casted attribute value
    #
    # @param [Object] new_value
    # @return [NilClass]
    def value=(new_value)
      value_will_change! unless value == new_value
      @attributes[:value] = new_value
      if column.sql_type == "polymorphic_association"
        
        if new_value.is_a?(::ActiveRecord::Base)
          @value_id = new_value.id
          @value_type = new_value.class.to_s
        elsif new_value.is_a?(::String) && (new_value.to_i.to_s != new_value)
          @value_type = new_value
        elsif new_value.is_a?(::String) && (new_value.to_i.to_s == new_value)
          @value_id = new_value.to_i
        elsif new_value.is_a?(::Fixnum)
          @value_id = new_value
        else 
          Rails.logger.error("Value for #{self.hydra_attribute.name} must be an ActiveRecord::Base object but is #{new_value}")
        end
      else
        @value = column.type_cast(new_value)
      end
    end
    
    # Sets new type casted attribute value_id
    #
    # @param [Object] new_value
    # @return [NilClass]
    def value_id=(new_value)
      value_will_change! unless value_id == new_value
      
      if new_value.to_i == 0
        @value_id = @value_type = nil
        @attributes[:value_id] = new_value   = nil
      else  
        @attributes[:value_id] = new_value  
        @value_id = column.type_cast(new_value)
      end
    end
    
    
    # Sets new type casted attribute value_type
    #
    # @param [Object] new_value
    # @return [NilClass]
    def value_type=(new_value)
      value_will_change! unless value_type == new_value
      @attributes[:value_type] = new_value  
      @value_type = column.type_cast(new_value)
    end
    

    # Returns not type cased value
    #
    # @return [Object]
    def value_before_type_cast
      @attributes[:value]
    end

    # Checks if value not blank and not zero for number types
    #
    # @return [TrueClass, FalseClass]
    def value?
      return false unless value

      if column.number?
        !value.zero?
      else
        value.present?
      end
    end

    # Returns hydra attribute model which contains meta information about attribute
    #
    # @return [HydraAttribute::HydraAttribute]
    def hydra_attribute
      @hydra_attribute ||= ::HydraAttribute::HydraAttribute.find(@attributes[:hydra_attribute_id])
    end

    # Checks if model is persisted
    #
    # @return [TrueClass, FalseClass]
    def persisted?
      @attributes[:id].present?
    end

    # Saves model
    # Performs +insert+ or +update+ sql query
    # Method doesn't perform sql query if model isn't modified
    #
    # @return [TrueClass, FalseClass]
    def save
      raise EntityModelIsNotPersistedError unless entity.persisted?

      if persisted?
        return false unless changed?
        update
      else
        create
      end

      @previously_changed = changes
      @changed_attributes.clear

      true
    end

    private
      # Creates arel insert manager
      #
      # @return [Arel::InsertManager]
  
      
      def arel_insert

        table  = self.class.arel_tables[entity.class.table_name][hydra_attribute.backend_type]
        fields = {}
        
      
        
        fields[table[:entity_id]]          = entity.id
        fields[table[:hydra_attribute_id]] = hydra_attribute.id
        if column.sql_type == "polymorphic_association"
          fields[table[:value_id]]    = value_id
          fields[table[:value_type]]  = value_type
        else
          fields[table[:value]] = value
        end
        fields[table[:created_at]]         = Time.now
        fields[table[:updated_at]]         = Time.now
        table.compile_insert(fields)
        
        
      end

      # Creates arel update manager
      #
      # @return [Arel::UpdateManager]
      def arel_update
        table = self.class.arel_tables[entity.class.table_name][hydra_attribute.backend_type]
        arel  = table.from(table)

        if column.sql_type == "polymorphic_association"
          arel.where(table[:id].eq(id)).compile_update({table[:value_id] => value_id, table[:value_type] => value_type, table[:updated_at] => Time.now}, id)
        else
          arel.where(table[:id].eq(id)).compile_update({table[:value] => value, table[:updated_at] => Time.now}, id)          
        end
      end

      # Performs sql insert query
      #
      # @return [Integer] primary key
      def create
        @attributes[:id] = self.class.connection.insert(arel_insert, 'SQL')
      end

      # Performs sql update query
      #
      # @return [NilClass]
      def update
        self.class.connection.update(arel_update, 'SQL')
      end
  end
end
