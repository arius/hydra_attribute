module HydraAttribute
  module ActiveRecord
    module Relation
      module QueryMethods
        extend ActiveSupport::Concern

        MULTI_VALUE_METHODS = [:hydra_joins_aliases]

        included do
          attr_writer *MULTI_VALUE_METHODS

          MULTI_VALUE_METHODS.each do |value|
            class_eval <<-EOS, __FILE__, __LINE__ + 1
              def #{value}; @#{value} ||= [] end
            EOS
          end

          alias_method_chain :where, :hydra_attribute
        end

        def where_with_hydra_attribute(opts, *rest)
          return self if opts.blank?

          if opts.is_a?(Hash)
            opts.inject(self) do |relation, (name, value)|
              if klass.hydra_attribute_names.include?(name)
                relation = relation.clone
                relation.hydra_joins_aliases << hydra_ref_alias(name, value)
                relation.joins_values += build_hydra_joins_values(name, value)
                relation.where_values += build_where(build_hydra_where_options(name, value))
                relation
              else
                relation.where_without_hydra_attribute(name => value)
              end
            end
          else
            where_without_hydra_attribute(opts, *rest)
          end
        end

        # Update hydra attribute name and join appropriate table
        def build_arel
          @order_values = build_order_values_for_arel(@order_values)

          if instance_variable_defined?(:@reorder_value) and instance_variable_get(:@reorder_value).present? # 3.1.x
            @reorder_value = build_order_values_for_arel(@reorder_value)
          end

          super
        end

        private

        def build_order_values_for_arel(collection)
          collection.map do |attribute|
            next attribute unless klass.hydra_attribute_names.include?(attribute)

            join_alias = hydra_ref_alias(attribute, 'inner') # alias for inner join
            join_alias = hydra_ref_alias(attribute, nil) unless hydra_joins_aliases.include?(join_alias) # alias for left join

            @joins_values += build_hydra_joins_values(attribute, nil) unless hydra_joins_aliases.include?(join_alias)
            klass.connection.quote_table_name(join_alias) + '.' + klass.connection.quote_column_name('value')
          end
        end

        def build_hydra_joins_values(name, value)
          ref_alias        = hydra_ref_alias(name, value)
          conn             = klass.connection
          quoted_ref_alias = conn.quote_table_name(ref_alias)

          [[
            "#{hydra_join_type(value)} JOIN",
            conn.quote_table_name(hydra_ref_table(name)),
            'AS',
            quoted_ref_alias,
            'ON',
            "#{klass.quoted_table_name}.#{klass.quoted_primary_key}",
            '=',
            "#{quoted_ref_alias}.#{conn.quote_column_name(:entity_id)}",
            'AND',
            "#{quoted_ref_alias}.#{conn.quote_column_name(:entity_type)}",
            '=',
            conn.quote(klass.base_class.name),
            'AND',
            "#{quoted_ref_alias}.#{conn.quote_column_name(:name)}",
            '=',
            conn.quote(name)
          ].join(' ')]
        end

        def build_hydra_where_options(name, value)
          {hydra_ref_alias(name, value).to_sym => {value: value}}
        end

        def hydra_ref_class(name)
          type = klass.hydra_attributes[name]
          HydraAttribute.config.associated_model_name(type).constantize
        end

        def hydra_ref_table(name)
          hydra_ref_class(name).table_name
        end

        def hydra_ref_alias(name, value)
          hydra_ref_table(name) + '_' + hydra_join_type(value).downcase + '_' + name.to_s
        end

        def hydra_join_type(value)
          value.nil? ? 'LEFT' : 'INNER'
        end
      end
    end
  end
end